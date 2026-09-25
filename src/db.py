import pymysql
import os
from datetime import datetime
DB_CONFIG={
  'host': os.emviron.get('DB_HOST','127.0.0.1'),
  'port': int(os.environ.get('DB_PORT',3306)),
  'user': os.environ.get('DB_USER','root'),
  'password': os.environ.get('DB_PASS','0'),
  'database': os.environ.get('DB_NAME','falco_alerts'),
  'charset':'utf8mb4'
}
def get_connection():
    return pymysql.connect(**DB_CONFIG)

def insert_alert(rule_name, priority, container_id, container_image,
                 process_name, user_name, output_text, attack_stage, chain_id):
    conn = get_connection()
    cursor = conn.cursor()
    sql = """INSERT INTO alerts
             (rule_name, priority, container_id, container_image, process_name,
              user_name, output_text, attack_stage, chain_id)
             VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)"""
    cursor.execute(sql, (rule_name, priority, container_id, container_image,
                         process_name, user_name, output_text, attack_stage, chain_id))
    alert_id = cursor.lastrowid
    conn.commit()
    cursor.close()
    conn.close()
    return alert_id

def insert_dread_score(alert_id, damage, reproducibility, exploitability,
                       affected_users, discoverability, total_score, risk_level):
    conn = get_connection()
    cursor = conn.cursor()
    sql = """INSERT INTO dread_scores
             (alert_id, damage, reproducibility, exploitability, affected_users,
              discoverability, total_score, risk_level)
             VALUES (%s, %s, %s, %s, %s, %s, %s, %s)"""
    cursor.execute(sql, (alert_id, damage, reproducibility, exploitability,
                         affected_users, discoverability, total_score, risk_level))
    conn.commit()
    cursor.close()
    conn.close()

def insert_dynamic_policy(policy_name, blocked_images, blocked_users, severity, alert_id):
    conn = get_connection()
    cursor = conn.cursor()
    sql = """INSERT INTO dynamic_policies
             (policy_name, blocked_images, blocked_users, severity, triggered_by_alert_id)
             VALUES (%s, %s, %s, %s, %s)"""
    cursor.execute(sql, (policy_name, ','.join(blocked_images),
                         ','.join(blocked_users), severity, alert_id))
    conn.commit()
    cursor.close()
    conn.close()

def get_alerts_by_chain(chain_id):
    conn = get_connection()
    cursor = conn.cursor(pymysql.cursors.DictCursor)
    cursor.execute("SELECT * FROM alerts WHERE chain_id = %s ORDER BY timestamp", (chain_id,))
    rows = cursor.fetchall()
    cursor.close()
    conn.close()
    return rows
