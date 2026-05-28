# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "9e7cdf78-6b9e-4d93-a012-1b8ceb565a98",
# META       "default_lakehouse_name": "AetherLH",
# META       "default_lakehouse_workspace_id": "61ade7e2-7daf-48c4-b330-02b33007e4f5",
# META       "known_lakehouses": [
# META         {
# META           "id": "9e7cdf78-6b9e-4d93-a012-1b8ceb565a98"
# META         }
# META       ]
# META     }
# META   }
# META }

# CELL ********************

%pip install azure-eventhub==5.11.6

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

import json
import logging
import os
import random
import time
import traceback
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import pandas as pd
from azure.eventhub import EventData, EventHubProducerClient, TransportType

warnings_filter_msg = "ignore"
logging.getLogger("azure.eventhub").setLevel(logging.WARNING)

print("Imports loaded")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# Required: set this in notebook environment variables or a secret-backed config cell.
CONNECTION_STRING = os.getenv("AETHER_EVENTHUB_CONNECTION_STRING", "")

# Simulator controls
SIMULATION_MODE = "COMPRESSED"  # REALTIME | COMPRESSED
SIMULATION_SPEED = 5.0  # 1.0 = real-time pacing
UPDATE_INTERVAL_SECONDS = 1
TOTAL_EVENTS = 400
BATCH_SIZE = 20
NOISE_RATE = 0.35  # 0.0 to 1.0
SEED = 42
SCENARIO_ID = "aether-night-001"

# Narrative roster
CHARACTERS = {
    1: "Julian Croft",
    2: "Evelyn Reed",
    3: "Marcus Thorne",
    4: "Anya Sharma",
    5: "Dr. Alistair Finch",
}

LOCATIONS = {
    101: "Julian's Study",
    102: "Server Room",
    103: "Evelyn's Suite",
    104: "Marcus's Suite",
    105: "Back Path",
    106: "Dr. Finch's Suite",
}

if not CONNECTION_STRING:
    raise ValueError(
        "AETHER_EVENTHUB_CONNECTION_STRING is empty. Set it before running the stream."
    )

random.seed(SEED)
RUN_ID = datetime.now(timezone.utc).strftime("run-%Y%m%d-%H%M%S")
SIM_START = datetime.now(timezone.utc)

print(f"Run ID: {RUN_ID}")
print(f"Scenario: {SCENARIO_ID}")
print(f"Total events: {TOTAL_EVENTS} | Batch size: {BATCH_SIZE}")
print(f"Mode: {SIMULATION_MODE} | Speed: {SIMULATION_SPEED}x")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

SCRIPTED_MILESTONES = [
    {
        "offset": 0,
        "security": {
            "PersonID": 1,
            "LocationID": 101,
            "EventType": "Access Granted",
        },
        "comms": {
            "CommsType": "Email",
            "Sender": "Evelyn Reed",
            "Recipient": "Julian Croft",
            "Subject": "RE: Code Ownership",
            "Body": "We need to discuss what happened to my original architecture.",
            "Status": "Sent",
        },
    },
    {
        "offset": 45,
        "security": {
            "PersonID": 3,
            "LocationID": 101,
            "EventType": "Movement Detected",
        },
        "comms": {
            "CommsType": "TextMessage",
            "Sender": "Marcus Thorne",
            "Recipient": "Julian Croft",
            "Subject": "",
            "Body": "Stop ignoring me. We settle this tonight.",
            "Status": "Delivered",
        },
    },
    {
        "offset": 75,
        "security": {
            "PersonID": 2,
            "LocationID": 102,
            "EventType": "Server Access",
        },
        "comms": {
            "CommsType": "LogEntry",
            "Sender": "AetherSystem",
            "Recipient": "OpsTeam",
            "Subject": "Server Access Alert",
            "Body": "Unexpected late-night server room access observed.",
            "Status": "Archived",
        },
    },
    {
        "offset": 150,
        "security": {
            "PersonID": 5,
            "LocationID": 101,
            "EventType": "Door Unlock",
        },
        "comms": {
            "CommsType": "PhoneCall",
            "Sender": "Security",
            "Recipient": "OpsTeam",
            "Subject": "Emergency",
            "Body": "Body discovered in study. Lockdown initiated.",
            "Status": "Delivered",
        },
    },
]

SECURITY_EVENT_TYPES = [
    "Access Granted",
    "Access Denied",
    "Movement Detected",
    "Server Access",
    "Door Unlock",
    "Alarm Triggered",
    "Network Activity",
    "Power State Change",
]

COMM_TYPES = ["Email", "TextMessage", "Slack", "PhoneCall", "LogEntry"]


@dataclass
class StreamEvent:
    event_id: str
    event_type: str
    payload: dict


def _event_time_for(index: int) -> datetime:
    return SIM_START + timedelta(seconds=index * UPDATE_INTERVAL_SECONDS)


def make_security_event(index: int, scripted: dict | None) -> StreamEvent:
    event_time = _event_time_for(index)

    if scripted:
        body = scripted
    else:
        person_id = random.choice(list(CHARACTERS.keys()))
        location_id = random.choice(list(LOCATIONS.keys()))
        body = {
            "PersonID": person_id,
            "LocationID": location_id,
            "EventType": random.choice(SECURITY_EVENT_TYPES),
        }

    payload = {
        "event_type": "SecurityLogs",
        "event_id": f"{RUN_ID}-sec-{index}",
        "run_id": RUN_ID,
        "scenario_id": SCENARIO_ID,
        "event_time_utc": event_time.isoformat(),
        "ingest_time_utc": datetime.now(timezone.utc).isoformat(),
        **body,
    }

    return StreamEvent(payload["event_id"], "SecurityLogs", payload)


def make_comms_event(index: int, scripted: dict | None) -> StreamEvent:
    event_time = _event_time_for(index)

    if scripted:
        body = scripted
    else:
        sender_id = random.choice(list(CHARACTERS.keys()))
        recipient_id = random.choice(list(CHARACTERS.keys()))
        body = {
            "CommsType": random.choice(COMM_TYPES),
            "Sender": CHARACTERS[sender_id],
            "Recipient": CHARACTERS[recipient_id],
            "Subject": "Routine check-in",
            "Body": "Background operational traffic.",
            "Status": random.choice(["Sent", "Delivered", "Archived"]),
        }

    payload = {
        "event_type": "Communications",
        "event_id": f"{RUN_ID}-com-{index}",
        "run_id": RUN_ID,
        "scenario_id": SCENARIO_ID,
        "event_time_utc": event_time.isoformat(),
        "ingest_time_utc": datetime.now(timezone.utc).isoformat(),
        "Timestamp": event_time.isoformat(),
        **body,
    }

    return StreamEvent(payload["event_id"], "Communications", payload)


def build_event_pairs(total_events: int) -> list[StreamEvent]:
    scripted_by_offset = {m["offset"]: m for m in SCRIPTED_MILESTONES}
    out: list[StreamEvent] = []

    for i in range(total_events):
        milestone = scripted_by_offset.get(i)
        scripted_security = milestone["security"] if milestone else None
        scripted_comms = milestone["comms"] if milestone else None

        out.append(make_security_event(i, scripted_security))

        # Hybrid mode: add communication noise based on NOISE_RATE or milestone.
        if scripted_comms or random.random() < NOISE_RATE:
            out.append(make_comms_event(i, scripted_comms))

    return out


events = build_event_pairs(TOTAL_EVENTS)
print(f"Prepared {len(events)} events for publish")

# Preview a few events for schema sanity.
pd.DataFrame([e.payload for e in events[:3]])

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

producer = EventHubProducerClient.from_connection_string(
    CONNECTION_STRING,
    transport_type=TransportType.AmqpOverWebsocket,
    retry_total=3,
)


def publish_events(all_events: list[StreamEvent]) -> tuple[int, int]:
    sent = 0
    failed = 0

    # Keep a tiny pacing delay for near-real-time playback during demos.
    sleep_s = UPDATE_INTERVAL_SECONDS / SIMULATION_SPEED if SIMULATION_MODE else 0

    for i in range(0, len(all_events), BATCH_SIZE):
        batch_events = all_events[i : i + BATCH_SIZE]
        event_batch = producer.create_batch()

        try:
            for e in batch_events:
                event_batch.add(EventData(json.dumps(e.payload)))

            producer.send_batch(event_batch)
            sent += len(batch_events)

        except Exception:
            failed += len(batch_events)
            traceback.print_exc()

        if sent > 0 and sent % 100 == 0:
            print(f"Progress: sent={sent} failed={failed}")

        if sleep_s > 0:
            time.sleep(sleep_s)

    return sent, failed


start_ts = time.time()
try:
    sent_count, failed_count = publish_events(events)
finally:
    producer.close()

elapsed = time.time() - start_ts
print("Stream complete")
print(f"Run ID: {RUN_ID}")
print(f"Sent: {sent_count} | Failed: {failed_count}")
print(f"Elapsed: {elapsed:.2f}s")
if elapsed > 0:
    print(f"Throughput: {sent_count / elapsed:.2f} events/sec")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
