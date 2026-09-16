"""
02_feature_engineering_and_models.py
-------------------------------------
Feature engineering + one classification model per funnel stage:
  Delivered -> Read -> Responded -> Converted   (+ Opt-out risk, separate branch)

Each stage is trained only on the population eligible for it (e.g. "Read"
model only trains on messages that were actually delivered) -- this mirrors
how a real marketing data science team would build a funnel model.
"""

import pandas as pd
import numpy as np
import json
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import OneHotEncoder
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.metrics import (accuracy_score, precision_score, recall_score,
                              f1_score, roc_auc_score)

df = pd.read_csv("whatsapp_campaign_dataset.csv")
df["send_date"] = pd.to_datetime(df["send_date"])
df["month"] = df["send_date"].dt.month
df["is_weekend"] = df["day_of_week"].isin(["Saturday", "Sunday"]).astype(int)
df["is_evening_send"] = df["send_hour"].between(18, 22).astype(int)
df["tenure_band"] = pd.cut(df["tenure_days"], bins=[0, 90, 365, 900],
                            labels=["New (<90d)", "Established (90-365d)", "Loyal (>365d)"])

CAT_FEATURES = ["message_type", "day_of_week", "city_tier", "age_group",
                 "device_type", "signup_channel", "tenure_band"]
NUM_FEATURES = ["send_hour", "tenure_days", "is_weekend", "is_evening_send", "month"]
FEATURES = CAT_FEATURES + NUM_FEATURES

STAGES = [
    ("delivered", df, "Message Delivery Prediction"),
    ("read", df[df.delivered == 1], "Message Read Prediction"),
    ("responded", df[df.read == 1], "Response Probability"),
    ("converted", df[df.responded == 1], "Conversion Probability"),
    ("opted_out", df[df.delivered == 1], "Opt-Out Risk"),
]

results = {}
feature_importances = {}

for target, subset, label in STAGES:
    subset = subset.dropna(subset=[target]).copy()
    X = subset[FEATURES]
    y = subset[target].astype(int)

    if y.nunique() < 2 or len(subset) < 30:
        results[target] = {"label": label, "note": "insufficient class variation to train"}
        continue

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.25, random_state=42, stratify=y
    )

    preprocess = ColumnTransformer([
        ("cat", OneHotEncoder(handle_unknown="ignore"), CAT_FEATURES),
    ], remainder="passthrough")

    clf = Pipeline([
        ("prep", preprocess),
        ("model", RandomForestClassifier(
            n_estimators=300, max_depth=8, min_samples_leaf=5,
            class_weight="balanced", random_state=42, n_jobs=-1)),
    ])

    clf.fit(X_train, y_train)
    y_pred = clf.predict(X_test)
    y_proba = clf.predict_proba(X_test)[:, 1]

    metrics = {
        "label": label,
        "n_train": len(X_train),
        "n_test": len(X_test),
        "positive_rate": round(float(y.mean()), 3),
        "accuracy": round(accuracy_score(y_test, y_pred), 3),
        "precision": round(precision_score(y_test, y_pred, zero_division=0), 3),
        "recall": round(recall_score(y_test, y_pred, zero_division=0), 3),
        "f1_score": round(f1_score(y_test, y_pred, zero_division=0), 3),
        "roc_auc": round(roc_auc_score(y_test, y_proba), 3) if y.nunique() == 2 else None,
    }
    results[target] = metrics

    # feature importance (map back through one-hot encoder)
    ohe = clf.named_steps["prep"].named_transformers_["cat"]
    ohe_names = list(ohe.get_feature_names_out(CAT_FEATURES))
    all_names = ohe_names + NUM_FEATURES
    importances = clf.named_steps["model"].feature_importances_
    fi = sorted(zip(all_names, importances), key=lambda x: -x[1])[:10]
    feature_importances[target] = [{"feature": f, "importance": round(float(v), 4)} for f, v in fi]

    # score the FULL dataset (not just test set) so we can export scored leads
    subset["predicted_" + target + "_probability"] = clf.predict_proba(X)[:, 1]
    subset[["message_id", "contact_id", "predicted_" + target + "_probability"]].to_csv(
        f"scored_{target}.csv", index=False
    )

    print(f"[{label}] n={len(subset)} pos_rate={metrics['positive_rate']} "
          f"acc={metrics['accuracy']} auc={metrics['roc_auc']}")

with open("model_results.json", "w") as f:
    json.dump({"metrics": results, "feature_importance": feature_importances}, f, indent=2)

# ---------------------------------------------------------------------------
# Build one merged "lead scoring" table: contact-level probabilities for
# every funnel stage on their most recent message -- this is the artifact a
# marketing team would actually act on.
# ---------------------------------------------------------------------------
latest = df.sort_values("send_date").groupby("contact_id").tail(1)[
    ["contact_id", "message_id"]
].reset_index(drop=True)

for target, _, _ in STAGES:
    path = f"scored_{target}.csv"
    try:
        scored = pd.read_csv(path)
        latest = latest.merge(
            scored[["message_id", f"predicted_{target}_probability"]],
            on="message_id", how="left"
        )
    except FileNotFoundError:
        pass

latest = latest.merge(
    df.drop_duplicates("contact_id")[["contact_id", "city_tier", "age_group",
                                       "device_type", "signup_channel", "tenure_days"]],
    on="contact_id", how="left"
)
latest.to_csv("contact_lead_scores.csv", index=False)
print("\nSaved contact_lead_scores.csv with", latest.shape[0], "contacts scored across all funnel stages.")
