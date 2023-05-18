#!/bin/bash

# aws cloudwatch
cat <<EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "metrics": {
    "metrics_collected": {
      "collectd": {
        "metrics_aggregation_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      }
    },
    "append_dimensions": {
      "ImageId": "\${!aws:ImageId}",
      "InstanceId": "\${!aws:InstanceId}",
      "InstanceType": "\${!aws:InstanceType}",
      "AutoScalingGroupName": "\${!aws:AutoScalingGroupName}"
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/dpkg.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/dpkg.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/apt/history.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/apt/history.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/cloud-init.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/cloud-init.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/cloud-init-output.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/auth.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/auth.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/syslog",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/amazon/ssm/amazon-ssm-agent.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/amazon/ssm/amazon-ssm-agent.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/amazon/ssm/errors.log",
            "log_group_name": "${AsgSystemLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/amazon/ssm/errors.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/peertube.access.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/nginx/peertube.access.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/peertube.error.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-/var/log/nginx/peertube.error.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/www/peertube/storage/logs/peertube.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-/var/www/peertube/storage/logs/peertube.log",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/www/peertube/storage/logs/peertube-audit.log",
            "log_group_name": "${AsgAppLogGroup}",
            "log_stream_name": "{instance_id}-/var/www/peertube/storage/logs/peertube-audit.log",
            "timezone": "UTC"
          }
        ]
      }
    },
    "log_stream_name": "{instance_id}"
  }
}
EOF
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# apache
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/nginx-selfsigned.key \
  -out /etc/ssl/certs/nginx-selfsigned.crt \
  -subj '/CN=localhost'

mkdir -p /opt/oe/patterns

# secretsmanager
SECRET_ARN="${DbSecretArn}"
echo $SECRET_ARN > /opt/oe/patterns/secret-arn.txt
SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?ARN=='$SECRET_ARN'].Name" --output text)
echo $SECRET_NAME > /opt/oe/patterns/secret-name.txt

aws ssm get-parameter \
    --name "/aws/reference/secretsmanager/$SECRET_NAME" \
    --with-decryption \
    --query Parameter.Value \
| jq -r . > /opt/oe/patterns/secret.json

DB_PASSWORD=$(cat /opt/oe/patterns/secret.json | jq -r .password)
DB_USERNAME=$(cat /opt/oe/patterns/secret.json | jq -r .username)

/root/check-secrets.py ${AWS::Region} ${InstanceSecretName}

aws ssm get-parameter \
    --name "/aws/reference/secretsmanager/${InstanceSecretName}" \
    --with-decryption \
    --query Parameter.Value \
| jq -r . > /opt/oe/patterns/instance.json

ACCESS_KEY_ID=$(cat /opt/oe/patterns/instance.json | jq -r .access_key_id)
APP_KEY=$(cat /opt/oe/patterns/instance.json | jq -r .app_key)
SECRET_ACCESS_KEY=$(cat /opt/oe/patterns/instance.json | jq -r .secret_access_key)
SMTP_PASSWORD=$(cat /opt/oe/patterns/instance.json | jq -r .smtp_password)
ROOT_PASSWORD=$(cat /opt/oe/patterns/instance.json | jq -r .root_password)

echo "${DbCluster.Endpoint.Address}:5432:peertube:peertube:$DB_PASSWORD" > /root/.pgpass
chmod 600 /root/.pgpass
psql -U peertube -h ${DbCluster.Endpoint.Address} -d peertube -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"
psql -U peertube -h ${DbCluster.Endpoint.Address} -d peertube -c "CREATE EXTENSION IF NOT EXISTS unaccent"
rm /root/.pgpass

mkdir -p /data/storage
chown peertube:peertube /data/storage
cd /var/www/peertube
ln -s /data/storage storage

mkdir -p /data/config
chown peertube:peertube /data/config
chmod 750 /data/config
ln -s /data/config config

sudo -u peertube cp peertube-latest/config/default.yaml config/default.yaml
sudo -u peertube cp peertube-latest/config/production.yaml.example config/production.yaml
sed -i 's/example.com/${Hostname}/g' config/production.yaml
sed -i "/^secrets:/{N;N;s/peertube: ''/peertube: '$APP_KEY'/}" config/production.yaml
sed -i "/^database:/{N;s/hostname: 'localhost'/hostname: '${DbCluster.Endpoint.Address}'/}" config/production.yaml
sed -i "/^database:/{N;N;N;N;s/suffix: '_prod'/name: 'peertube'/}" config/production.yaml
sed -i "/^database:/{N;N;N;N;N;N;s|password: 'peertube'|password: '$DB_PASSWORD'|}" config/production.yaml
sed -i "/^redis:/{N;s/hostname: 'localhost'/hostname: '${RedisCluster.RedisEndpoint.Address}'/}" config/production.yaml
sed -i "/^redis:/{N;N;s/port: 6379/port: ${RedisCluster.RedisEndpoint.Port}/}" config/production.yaml
sed -i "/^smtp:/{N;N;N;N;N;s/hostname: null/hostname: 'email-smtp.${AWS::Region}.amazonaws.com'/}" config/production.yaml
sed -i "/^smtp:/{N;N;N;N;N;N;s/port: 465/port: 587/}" config/production.yaml
sed -i "/^smtp:/{N;N;N;N;N;N;N;s/username: null/username: '$ACCESS_KEY_ID'/}" config/production.yaml
sed -i "/^smtp:/{N;N;N;N;N;N;N;N;s|password: null|password: '$SMTP_PASSWORD'|}" config/production.yaml
sed -i "/^smtp:/{N;N;N;N;N;N;N;N;N;s/tls: true/tls: false/}" config/production.yaml
sed -i "/^signup:/{N;s/enabled: false/enabled: true/}" config/production.yaml
sed -i "/^signup:/{N;N;N;s/limit: 10/limit: -1/}" config/production.yaml
sed -i "s/requires_email_verification: false/requires_email_verification: true/" config/production.yaml
sed -i "/^object_storage:/{N;s/enabled: false/enabled: true/}" config/production.yaml
sed -i "/^object_storage:/{N;N;N;N;s/endpoint: ''/endpoint: 's3.${AWS::Region}.amazonaws.com'/}" config/production.yaml
sed -i "/^object_storage:/{N;N;N;N;N;N;s/region: 'us-east-1'/region: '${AWS::Region}'/}" config/production.yaml
sed -i "s/access_key_id: ''/access_key_id: '$ACCESS_KEY_ID'/" config/production.yaml
sed -i "s|secret_access_key: ''|secret_access_key: '$SECRET_ACCESS_KEY'|" config/production.yaml
sed -i "s/bucket_name: 'streaming-playlists'/bucket_name: '${AssetsBucketName}'/" config/production.yaml
sed -i "s/bucket_name: 'videos'/bucket_name: '${AssetsBucketName}'/" config/production.yaml
sed -i "/Allows setting all buckets/{N;s|prefix: ''|prefix: 'streaming-playlists/'|}" config/production.yaml
sed -i "/Same settings but for webtorrent videos/{N;N;N;s|prefix: ''|prefix: 'videos/'|}" config/production.yaml
if [ -n "${AdminEmail}" ]; then
    sed -i "/^admin:/{N;N;N;s/email: 'admin@${Hostname}'/email: '${AdminEmail}'/}" config/production.yaml
fi
sed -i "s/from_address: 'admin@${Hostname}'/from_address: 'no-reply@${Hostname}'/" config/production.yaml


cp /var/www/peertube/peertube-latest/support/nginx/peertube /etc/nginx/sites-available/peertube
rm -f /etc/nginx/sites-enabled/default
echo "server_names_hash_bucket_size 128;" >> /etc/nginx/sites-available/peertube
sed -i 's/${!WEBSERVER_HOST}/${Hostname}/g' /etc/nginx/sites-available/peertube
sed -i 's/${!PEERTUBE_HOST}/127.0.0.1:9000/g' /etc/nginx/sites-available/peertube
sed -i 's|/etc/letsencrypt/live/${Hostname}/fullchain.pem|/etc/ssl/certs/nginx-selfsigned.crt|g' /etc/nginx/sites-available/peertube
sed -i 's|/etc/letsencrypt/live/${Hostname}/privkey.pem|/etc/ssl/private/nginx-selfsigned.key|g' /etc/nginx/sites-available/peertube
sed -i 's|ssl_stapling|# ssl_stapling|g' /etc/nginx/sites-available/peertube
sed -i "/error_log/a\  location /elb-check { access_log off; return 200 'ok'; add_header Content-Type text/plain; }" /etc/nginx/sites-available/peertube
sed -i "/error_log/a\  real_ip_header X-Forwarded-For;\n  set_real_ip_from ${VpcCidr};" /etc/nginx/sites-available/peertube

ln -s /etc/nginx/sites-available/peertube /etc/nginx/sites-enabled/peertube

systemctl restart nginx

cp /var/www/peertube/peertube-latest/support/sysctl.d/30-peertube-tcp.conf /etc/sysctl.d/
sysctl -p /etc/sysctl.d/30-peertube-tcp.conf

cp /var/www/peertube/peertube-latest/support/systemd/peertube.service /etc/systemd/system/
sed -i 's|After=network.target postgresql.service redis-server.service|After=network.target|g' /etc/systemd/system/peertube.service
sed -i "/Environment=NODE_CONFIG_DIR=\/var\/www\/peertube\/config/a Environment=PT_INITIAL_ROOT_PASSWORD=$ROOT_PASSWORD" /etc/systemd/system/peertube.service

systemctl daemon-reload
systemctl enable peertube
systemctl start peertube

systemctl restart peertube

success=$?
cfn-signal --exit-code $success --stack ${AWS::StackName} --resource Asg --region ${AWS::Region}
