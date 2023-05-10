#
# PeerTube configuration
#

PEERTUBE_VERSION=TODO

apt-get update
apt-get -y install curl sudo unzip vim

# install node 16.x
curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash - && \
apt-get install -y nodejs

# install yarn
npm install --global yarn

apt-get -y install        \
        nginx             \
        ffmpeg            \
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
VERSION=$(curl -s https://api.github.com/repos/chocobozzz/peertube/releases/latest | grep tag_name | cut -d '"' -f 4) && echo "Latest Peertube version is $VERSION"
cd /var/www/peertube
sudo -u peertube mkdir config storage versions
sudo -u peertube chmod 750 config/
cd /var/www/peertube/versions
sudo -u peertube wget -q "https://github.com/Chocobozzz/PeerTube/releases/download/${VERSION}/peertube-${VERSION}.zip"
sudo -u peertube unzip -q peertube-${VERSION}.zip && sudo -u peertube rm peertube-${VERSION}.zip
cd /var/www/peertube
sudo -u peertube ln -s versions/peertube-${VERSION} ./peertube-latest
cd ./peertube-latest && sudo -H -u peertube yarn install --production --pure-lockfile
