#!/bin/bash

# aws cloudwatch
sed -i 's/ASG_APP_LOG_GROUP_PLACEHOLDER/${AsgAppLogGroup}/g' /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed -i 's/ASG_SYSTEM_LOG_GROUP_PLACEHOLDER/${AsgSystemLogGroup}/g' /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# reprovision if access key is rotated
# access key serial: ${SesInstanceUserAccessKeySerial}

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
sed -i "/^database:/{N;s/hostname: '127.0.0.1'/hostname: '${DbCluster.Endpoint.Address}'/}" config/production.yaml
sed -i "/^database:/{N;N;N;N;s/suffix: '_prod'/name: 'peertube'/}" config/production.yaml
sed -i "/^database:/{N;N;N;N;N;N;s|password: 'peertube'|password: '$DB_PASSWORD'|}" config/production.yaml
sed -i "/^redis:/{N;s/hostname: '127.0.0.1'/hostname: '${RedisCluster.RedisEndpoint.Address}'/}" config/production.yaml
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
sed -i "/^object_storage:/{N;N;N;N;N;s/endpoint: ''/endpoint: 's3.${AWS::Region}.amazonaws.com'/}" config/production.yaml
sed -i "/^object_storage:/{N;N;N;N;N;N;N;s/region: 'us-east-1'/region: '${AWS::Region}'/}" config/production.yaml
sed -i "s/access_key_id: ''/access_key_id: '$ACCESS_KEY_ID'/" config/production.yaml
sed -i "s|secret_access_key: ''|secret_access_key: '$SECRET_ACCESS_KEY'|" config/production.yaml

# streaming_playlists
sed -i "215s/bucket_name: .*/bucket_name: '${AssetsBucketName}'/" config/production.yaml
sed -i "218s|prefix: .*|prefix: 'streaming-playlists/'|" config/production.yaml
sed -i "222s|base_url: .*|base_url: 'https://${CloudFrontDistribution.DomainName}'|" config/production.yaml

# web_videos
sed -i "231s/bucket_name: .*/bucket_name: '${AssetsBucketName}'/" config/production.yaml
sed -i "232s|prefix: .*|prefix: 'web-videos/'|" config/production.yaml
sed -i "233s|base_url: .*|base_url: 'https://${CloudFrontDistribution.DomainName}'|" config/production.yaml

# user_exports
sed -i "236s/bucket_name: .*/bucket_name: '${AssetsBucketName}'/" config/production.yaml
sed -i "237s|prefix: .*|prefix: 'user-exports/'|" config/production.yaml
sed -i "238s|base_url: .*|base_url: 'https://${CloudFrontDistribution.DomainName}'|" config/production.yaml

# original_video_files
sed -i "242s/bucket_name: .*/bucket_name: '${AssetsBucketName}'/" config/production.yaml
sed -i "243s|prefix: .*|prefix: 'original-video-files/'|" config/production.yaml
sed -i "244s|base_url: .*|base_url: 'https://${CloudFrontDistribution.DomainName}'|" config/production.yaml

if [ -n "${AdminEmail}" ]; then
    sed -i "/^admin:/{N;N;N;s/email: 'admin@${Hostname}'/email: '${AdminEmail}'/}" config/production.yaml
fi
sed -i "s/from_address: 'admin@${Hostname}'/from_address: 'no-reply@${Hostname}'/" config/production.yaml
sed -i "/audio-only/{N;N;N;N;s/480p: false/480p: true/}" config/production.yaml


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
