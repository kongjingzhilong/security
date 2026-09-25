CREATE DATABASE IF NOT EXISTS falco_alerts;
USE falco_alerts;
CREATE TABLE IF NOT EXISTS alerts (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    rule_name VARCHAR(255),
    priority VARCHAR(50),
    container_id VARCHAR(128),
    container_image VARCHAR(255),
    process_name VARCHAR(255),
    user_name VARCHAR(128),
    output_text TEXT,
    attack_stage INT DEFAULT 0,
    chain_id VARCHAR(64),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS dynamic_policies (
    id INT AUTO_INCREMENT PRIMARY KEY,
    policy_name VARCHAR(255),
    blocked_images TEXT,
    blocked_users TEXT,
    severity VARCHAR(50),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    triggered_by_alert_id INT 
) ENGINE=InnoDB DEFAULT CHAREST=utf8mb4;
