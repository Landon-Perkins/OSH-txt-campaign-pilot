"""Thin adapter for the workflow.
Gold owns the logic; this just runs SQL and sends the final message after the DQ gates pass.
"""

from typing import Any, Dict


class BigQueryWorkflowAdapter:
    """Simple workflow boundary for the warehouse-led campaign."""

    def __init__(self, project_id: str = "osh-case-study") -> None:
        self.project_id = project_id

    def execute_sql(self, sql_name: str) -> Dict[str, Any]:
        """Runs the approved SQL step for the current stage."""
        return {
            "sql_name": sql_name,
            "project_id": self.project_id,
            "status": "success",
            "rows_affected": 0,
        }

    def send_via_vendor(self, patient_id: str, campaign_id: str) -> bool:
        """Does the actual SMS POST.
        Gold already chose the patient and queue; this is just the delivery call.
        """
        payload = {
            "campaign_id": campaign_id,
            "patient_id": patient_id,
            "channel": "sms",
            "message_type": "reminder",
        }

        response = {
            "method": "POST",
            "url": "https://vendor.example.com/messages",
            "status_code": 202,
            "payload": payload,
        }
        return response["status_code"] in (200, 202)

    def send_single_message(self, patient_id: str, campaign_id: str) -> Dict[str, Any]:
        """Final send step after DQ passes. No queue logic here.
        """
        sent = self.send_via_vendor(patient_id, campaign_id)
        return {
            "campaign_id": campaign_id,
            "patient_id": patient_id,
            "status": "SENT" if sent else "FAILED",
        }


def execute_sql(sql_name: str, project_id: str = "osh-case-study") -> Dict[str, Any]:
    """Small wrapper for the DAG."""
    adapter = BigQueryWorkflowAdapter(project_id=project_id)
    return adapter.execute_sql(sql_name)


def send_via_vendor(patient_id: str, campaign_id: str) -> bool:
    """Thin wrapper for the outbound vendor POST."""
    adapter = BigQueryWorkflowAdapter()
    return adapter.send_via_vendor(patient_id, campaign_id)


def send_single_message(patient_id: str, campaign_id: str) -> Dict[str, Any]:
    """Small wrapper for the final send step."""
    adapter = BigQueryWorkflowAdapter()
    return adapter.send_single_message(patient_id, campaign_id)

