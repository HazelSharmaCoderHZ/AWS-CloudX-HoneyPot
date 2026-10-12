"""FastAPI backend for the HaaS security dashboard.

Endpoints:
  GET /health            - backend + AWS connectivity
  GET /api/stats         - aggregate KPIs
  GET /api/events        - recent events (paginated)
  GET /api/charts        - events over time + top IPs
  GET /api/pipeline      - best-effort pipeline health

All data comes from the real CowrieLogs DynamoDB table. If an AWS service
is unavailable, endpoints return a clear error rather than mock data.
"""

import time

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import dynamo, probes
from .config import (
    AWS_MODE, AWS_REGION, AWS_ENDPOINT_URL,
    HAA_DYNAMODB_TABLE, DATA_SOURCE_LABEL,
)

app = FastAPI(
    title="AWS-CloudX-HoneyPot Dashboard API",
    version="1.0.0",
    description="Security dashboard backend for the HaaS pipeline.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    """Backend + AWS connectivity check."""
    start = time.time()
    table_ok = dynamo.table_exists()
    latency_ms = int((time.time() - start) * 1000)
    return {
        "status": "ok" if table_ok else "degraded",
        "backend": "ok",
        "mode": AWS_MODE,
        "region": AWS_REGION,
        "endpoint": AWS_ENDPOINT_URL,
        "table": HAA_DYNAMODB_TABLE,
        "table_reachable": table_ok,
        "latency_ms": latency_ms,
        "data_source": DATA_SOURCE_LABEL,
    }


@app.get("/api/stats")
async def stats():
    """Aggregate KPIs over a bounded scan of CowrieLogs."""
    try:
        return dynamo.stats()
    except Exception as e:
        raise HTTPException(
            status_code=503,
            detail=f"Unable to query DynamoDB: {e}",
        )


@app.get("/api/events")
async def events(
    limit: int = Query(default=50, ge=1, le=500),
    src_ip: str = Query(default=None),
    session: str = Query(default=None),
):
    """Recent events, optionally filtered by src_ip or session."""
    try:
        if session:
            items = dynamo.query_by_session(session, limit=limit)
        elif src_ip:
            items = dynamo.query_by_ip(src_ip, limit=limit)
        else:
            items = dynamo.query_recent(limit=limit)
        return {
            "events": items,
            "count": len(items),
            "limit": limit,
            "data_source": DATA_SOURCE_LABEL,
        }
    except Exception as e:
        raise HTTPException(
            status_code=503,
            detail=f"Unable to query DynamoDB: {e}",
        )


@app.get("/api/charts")
async def charts(
    limit: int = Query(default=12, ge=1, le=100),
):
    """Events-over-time buckets and top source IPs."""
    try:
        return {
            "events_over_time": dynamo.events_over_time(limit_buckets=limit),
            "top_ips": dynamo.top_ips(limit=10),
            "data_source": DATA_SOURCE_LABEL,
        }
    except Exception as e:
        raise HTTPException(
            status_code=503,
            detail=f"Unable to query DynamoDB: {e}",
        )


@app.get("/api/pipeline")
async def pipeline():
    """Best-effort pipeline health. Never raises - always returns status."""
    try:
        return probes.pipeline_status()
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content={"mode": AWS_MODE, "error": str(e)},
        )


@app.get("/api/config")
async def config():
    """Public config for the frontend (no secrets)."""
    return {
        "mode": AWS_MODE,
        "region": AWS_REGION,
        "endpoint": AWS_ENDPOINT_URL,
        "table": HAA_DYNAMODB_TABLE,
        "data_source": DATA_SOURCE_LABEL,
    }