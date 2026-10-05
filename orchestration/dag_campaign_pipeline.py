"""Thin DAG for the OSH pilot.
Gold owns the ranking, capacity, and backfill logic; this just runs the SQL steps and hits the send adapter.
"""

from datetime import datetime
from pathlib import Path

from airflow import DAG
from airflow.operators.python import PythonOperator

from python_adapter import execute_sql, send_single_message

CAMPAIGN_ID = "OSH_PILOT_2026Q4"
PROJECT_ID = "osh-case-study"
SQL_ROOT = Path(__file__).resolve().parent.parent / "sql"

with DAG(
    dag_id="osh_pilot_campaign_pipeline",
    start_date=datetime(2026, 10, 5),
    schedule="0 8 * * 1",
    catchup=False,
    max_active_runs=1,
    tags=["osh", "pilot", "campaign"],
) as dag:
    bronze_load = PythonOperator(
        task_id="bronze_load",
        python_callable=execute_sql,
        op_kwargs={
            "sql_name": "bronze.01_bronze",
            "project_id": PROJECT_ID,
        },
    )

    bronze_dq = PythonOperator(
        task_id="bronze_dq",
        python_callable=execute_sql,
        op_kwargs={
            "sql_name": "dq.01_bronze_dq",
            "project_id": PROJECT_ID,
        },
    )

    silver_run = PythonOperator(
        task_id="silver_run",
        python_callable=execute_sql,
        op_kwargs={
            "sql_name": "silver.01_silver",
            "project_id": PROJECT_ID,
        },
    )

    silver_dq = PythonOperator(
        task_id="silver_dq",
        python_callable=execute_sql,
        op_kwargs={
            "sql_name": "dq.02_silver_dq",
            "project_id": PROJECT_ID,
        },
    )

    gold_run = PythonOperator(
        task_id="gold_run",
        python_callable=execute_sql,
        op_kwargs={
            "sql_name": "gold.01_gold",
            "project_id": PROJECT_ID,
        },
    )

    gold_dq = PythonOperator(
        task_id="gold_dq",
        python_callable=execute_sql,
        op_kwargs={
            "sql_name": "dq.03_gold_dq",
            "project_id": PROJECT_ID,
        },
    )

    send_message = PythonOperator(
        task_id="send_message",
        python_callable=send_single_message,
        op_kwargs={
            "patient_id": "P00000001",
            "campaign_id": CAMPAIGN_ID,
        },
    )

    (
        bronze_load
        >> bronze_dq
        >> silver_run
        >> silver_dq
        >> gold_run
        >> gold_dq
        >> send_message
    )
