# app.py
import io
import json
import os
import boto3
import pandas as pd
import requests
from datetime import datetime
from fastapi import FastAPI, BackgroundTasks, Request
from baseline import BaselineManager
from processor import process_file


import logging

# 1. SETUP LOGGING
# This creates a log file locally on the EC2 instance
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("app.log"), # Writes to file
        logging.StreamHandler()         # Also prints to terminal/console
    ]
)
logger = logging.getLogger("AnomalyDetectionApp")


app = FastAPI(title="Anomaly Detection Pipeline")

s3 = boto3.client("s3")
BUCKET_NAME = os.environ["BUCKET_NAME"]


def sync_logs_to_s3():
    """Syncs the local app.log to S3 logs/ folder."""
    try:
        s3.upload_file("app.log", BUCKET_NAME, "logs/app.log")
        logger.info("Successfully synced app.log to S3.")
    except Exception as e:
        logger.error(f"Failed to sync logs to S3: {e}")


# ── SNS subscription confirmation + message handler ──────────────────────────
@app.post("/notify")
async def handle_sns(request: Request, background_tasks: BackgroundTasks):
    try: 
        body = await request.json()
        msg_type = request.headers.get("x-amz-sns-message-type")

        # SNS sends a SubscriptionConfirmation before it will deliver any messages.
        # Visiting the SubscribeURL confirms the subscription.
        if msg_type == "SubscriptionConfirmation":
            confirm_url = body["SubscribeURL"]
            requests.get(confirm_url)
            logger.info("SNS Subscription Confirmed via URL.")
            return {"status": "confirmed"}

        if msg_type == "Notification":
            # The SNS message body contains the S3 event as a JSON string
            s3_event = json.loads(body["Message"])
            for record in s3_event.get("Records", []):
                key = record["s3"]["object"]["key"]
                if key.startswith("raw/") and key.endswith(".csv"):
                    logger.info(f"New file arrival detected: {key}")
                    # Process file and sync logs as background tasks
                    background_tasks.add_task(process_file, BUCKET_NAME, key)
                    background_tasks.add_task(sync_logs_to_s3) # Requirement: Sync logs
                    # Use the wrapper so sync_logs_to_s3 happens AFTER process_file
                    background_tasks.add_task(run_pipeline, BUCKET_NAME, key)

        return {"status": "ok"}
    except Exception as e:
        logger.error(f"Error in /notify: {str(e)}")
        return {"status": "error", "message": str(e)} 
    
async def run_pipeline(bucket, key):
    """Wrapper to ensure we log, process, and then sync to S3."""
    try:
        process_file(bucket, key)
        # Requirement: Sync log file to S3 whenever baseline is pushed
        sync_logs_to_s3() 
    except Exception as e:
        logger.error(f"Pipeline failed for {key}: {e}")
        sync_logs_to_s3() # Sync even on failure so you can see the error in S3!

# ── Query endpoints ───────────────────────────────────────────────────────────

@app.get("/anomalies/recent")
def get_recent_anomalies(limit: int = 50):
    """Return rows flagged as anomalies across the 10 most recent processed files."""
    try: 
        paginator = s3.get_paginator("list_objects_v2")
        pages = paginator.paginate(Bucket=BUCKET_NAME, Prefix="processed/")

        keys = sorted(
            [
                obj["Key"]
                for page in pages
                for obj in page.get("Contents", [])
                if obj["Key"].endswith(".csv")
            ],
            reverse=True,
        )[:10]

        all_anomalies = []
        for key in keys:
            response = s3.get_object(Bucket=BUCKET_NAME, Key=key)
            df = pd.read_csv(io.BytesIO(response["Body"].read()))
            if "anomaly" in df.columns:
                flagged = df[df["anomaly"] == True].copy()
                flagged["source_file"] = key
                all_anomalies.append(flagged)

        if not all_anomalies:
            return {"count": 0, "anomalies": []}

        combined = pd.concat(all_anomalies).head(limit)
        return {"count": len(combined), "anomalies": combined.to_dict(orient="records")}
    except Exception as e: 
        logger.error(f"Error in /notify: {str(e)}")
        return {"status": "error", "message": str(e)}


@app.get("/anomalies/summary")
def get_anomaly_summary():
    """Aggregate anomaly rates across all processed files using their summary JSONs."""
    try: 
        paginator = s3.get_paginator("list_objects_v2")
        pages = paginator.paginate(Bucket=BUCKET_NAME, Prefix="processed/")

        summaries = []
        for page in pages:
            for obj in page.get("Contents", []):
                if obj["Key"].endswith("_summary.json"):
                    response = s3.get_object(Bucket=BUCKET_NAME, Key=obj["Key"])
                    summaries.append(json.loads(response["Body"].read()))

        if not summaries:
            return {"message": "No processed files yet."}

        total_rows = sum(s["total_rows"] for s in summaries)
        total_anomalies = sum(s["anomaly_count"] for s in summaries)

        return {
            "files_processed": len(summaries),
            "total_rows_scored": total_rows,
            "total_anomalies": total_anomalies,
            "overall_anomaly_rate": round(total_anomalies / total_rows, 4) if total_rows > 0 else 0,
            "most_recent": sorted(summaries, key=lambda x: x["processed_at"], reverse=True)[:5],
        }
    except Exception as e: 
        logger.error(f"Failed to fetch recent anomalies: {e}")
        return {"status": "error", "message": "Check logs for details."}

@app.get("/baseline/current")
def get_current_baseline():
    """Show the current per-channel statistics the detector is working from."""
    try: 
        baseline_mgr = BaselineManager(bucket=BUCKET_NAME)
        baseline = baseline_mgr.load()

        channels = {}
        for channel, stats in baseline.items():
            if channel == "last_updated":
                continue
            channels[channel] = {
                "observations": stats["count"],
                "mean": round(stats["mean"], 4),
                "std": round(stats.get("std", 0.0), 4),
                "baseline_mature": stats["count"] >= 30,
            }

        return {
            "last_updated": baseline.get("last_updated"),
            "channels": channels,
        }
    except Exception as e:
        logger.error(f"Error loading baseline: {e}")
        return {"error": "Could not load baseline from S3"}

@app.get("/health")
def health():
    return {"status": "ok", "bucket": BUCKET_NAME, "timestamp": datetime.utcnow().isoformat()}
