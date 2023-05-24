#
# PeerTube configuration
#

# https://github.com/Chocobozzz/PeerTube/releases
VERSION=v5.1.0

apt-get update
apt-get -y install curl sudo unzip vim

# install node 16.x
curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash - && \
apt-get install -y nodejs

# install ffmpeg 6
mkdir /root/ffmpeg
cd /root/ffmpeg
wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz
tar -xvf ffmpeg-release-arm64-static.tar.xz
cp /root/ffmpeg/ffmpeg-6.0-arm64-static/ffmpeg /usr/bin/ffmpeg
cp /root/ffmpeg/ffmpeg-6.0-arm64-static/ffprobe /usr/bin/ffprobe

# install yarn
npm install --global yarn

apt-get -y install        \
        nginx             \
        postgresql-client \
        python3-dev       \
        python-is-python3 \
        openssl           \
        g++               \
        make              \
        git               \
        cron              \
        wget

useradd -m -d /var/www/peertube -s /bin/bash -p peertube peertube
chmod 755 /var/www/peertube
cd /var/www/peertube
sudo -u peertube mkdir versions
cd /var/www/peertube/versions
sudo -u peertube wget -q "https://github.com/Chocobozzz/PeerTube/releases/download/${VERSION}/peertube-${VERSION}.zip"
sudo -u peertube unzip -q peertube-${VERSION}.zip && sudo -u peertube rm peertube-${VERSION}.zip
cd /var/www/peertube
sudo -u peertube ln -s versions/peertube-${VERSION} ./peertube-latest
cd ./peertube-latest && sudo -H -u peertube yarn install --production --pure-lockfile

pip install boto3
cat <<EOF > /root/check-secrets.py
#!/usr/bin/env python3

import boto3
import json
import subprocess
import sys

region_name = sys.argv[1]
secret_name = sys.argv[2]

client = boto3.client("secretsmanager", region_name=region_name)
response = client.list_secrets(
  Filters=[{"Key": "name", "Values": [secret_name]}]
)
arn = response["SecretList"][0]["ARN"]
response = client.get_secret_value(
  SecretId=arn
)
current_secret = json.loads(response["SecretString"])
needs_update = False
if not 'app_key' in current_secret:
  needs_update = True
  cmd = "random_value=\$(seed=\$(date +%s%N); tr -dc '[:alnum:]' < /dev/urandom | head -c 32; echo \$seed | sha256sum | awk '{print substr(\$1, 1, 32)}'); echo \$random_value"
  output = subprocess.run(cmd, stdout=subprocess.PIPE, shell=True).stdout.decode('utf-8')
  current_secret['app_key'] = output
if not 'root_password' in current_secret:
  needs_update = True
  cmd = "random_value=\$(seed=\$(date +%s%N); tr -dc '[:alnum:]' < /dev/urandom | head -c 16; echo \$seed | sha256sum | awk '{print substr(\$1, 1, 16)}'); echo \$random_value"
  output = subprocess.run(cmd, stdout=subprocess.PIPE, shell=True).stdout.decode('utf-8')
  current_secret['root_password'] = output
if needs_update:
  client.update_secret(
    SecretId=arn,
    SecretString=json.dumps(current_secret)
  )
else:
  print('Secrets already generated - no action needed.')
EOF
chown root:root /root/check-secrets.py
chmod 744 /root/check-secrets.py
