#!/bin/bash

# How to use
# 1. Replace the "127.0.0.1" to 127.0.0.1
# 2. Run at the root -> source setup-taiga-centos.sh

yum install -y gcc autoconf flex bison libjpeg-turbo-devel
yum install -y freetype-devel zlib-devel zeromq-devel gdbm-devel ncurses-devel
yum install -y automake libtool libffi-devel curl git tmux
yum install -y libxml2-devel libxslt-devel
yum install -y wget openssl-devel gcc-c++

#PostgreSQL 9.5

wget http://yum.postgresql.org/9.5/redhat/rhel-7-x86_64/pgdg-centos95-9.5-2.noarch.rpm
rpm -ivh pgdg-centos95-9.5-2.noarch.rpm
yum install -y postgresql95-server postgresql95-devel postgresql95-contrib
export PATH=$PATH:/usr/pgsql-9.5/bin
postgresql95-setup initdb
systemctl start postgresql-9.5.service

#Python 3.5.1

wget https://www.python.org/ftp/python/3.5.1/Python-3.5.1.tar.xz
tar xvf Python-3.5.1.tar.xz
cd Python-3.5.1/
./configure --prefix=/opt/python3.5
make
make install
export PATH=$PATH:/opt/python3.5/bin

#PostgreSQL initDB setting

cd /home
su postgres -c "createuser taiga"
su postgres -c "createdb taiga -O taiga"

#pip
pip3.5 install virtualenv virtualenvwrapper
VIRTUALENVWRAPPER_PYTHON=/opt/python3.5/bin/python3.5
source /opt/python3.5/bin/virtualenvwrapper.sh
mkvirtualenv -p /opt/python3.5/bin/python3.5 taiga
deactivate

#taiga add
adduser taiga

#taiga-back
cd /home/taiga
git clone https://github.com/taigaio/taiga-back.git taiga-back
cd taiga-back/
git checkout stable

#pip with blackmagic
sed -i -e '34s/^/#/ig' requirements.txt
sed -i -e '34a git+https://github.com/Xof/django-pglocks.git' requirements.txt

pip3.5 install -r requirements.txt
pip3.5 install pycrypto
pip3.5 install pyjwkest
pip3.5 install pycryptodome

chown -R taiga:taiga /home/taiga/

sed -i -e '1a #!/opt/python3.5/bin/python3.5' -e '1d' manage.py

su taiga -c "python3.5 manage.py migrate --noinput"
su taiga -c "python3.5 manage.py loaddata initial_user"
su taiga -c "python3.5 manage.py loaddata initial_project_templates"
su taiga -c "python3.5 manage.py loaddata initial_role"
su taiga -c "python3.5 manage.py compilemessages"
su taiga -c "python3.5 manage.py collectstatic --noinput"

cat > /home/taiga/taiga-back/settings/local.py << EOF
from .development import *
from .common import *

MEDIA_URL = "http://127.0.0.1/media/"
STATIC_URL = "http://127.0.0.1/static/"
ADMIN_MEDIA_PREFIX = "http://127.0.0.1/static/admin/"
SITES["front"]["scheme"] = "http"
SITES["front"]["domain"] = "127.0.0.1"

SECRET_KEY = "CZWlOvqpak_vXAIeWF9Z"

DEBUG = False
TEMPLATE_DEBUG = False
PUBLIC_REGISTER_ENABLED = True

DEFAULT_FROM_EMAIL = "no-reply@example.com"
SERVER_EMAIL = DEFAULT_FROM_EMAIL

DATABASES = {
    'default': {
        'ENGINE': 'transaction_hooks.backends.postgresql_psycopg2',
        'NAME': 'taiga',
        'USER': 'taiga',
        'PASSWORD': 'vvf2_zBv5qUQJcYLZkM7',
        'HOST': '',
        'PORT': '',
    }
}
EOF

#libzmq
cd /home/taiga/
git clone https://github.com/zeromq/libzmq.git libzmq
cd libzmq/
./autogen.sh
./configure --without-libsodium
make
make install

#circus systemd setting
cat > /usr/lib/systemd/system/circus.service << EOF
[Unit]
Description=circus

[Service]
ExecStart=/usr/local/bin/circusd /home/taiga/conf/circus.ini
EOF
ln -s '/usr/lib/systemd/system/circus.service' '/etc/systemd/system/circus.service'

#taiga-front
cd /home/taiga
git clone https://github.com/taigaio/taiga-front-dist.git taiga-front-dist
cd taiga-front-dist/
git checkout stable
cd dist/
sed -e 's/localhost/127.0.0.1/' conf.example.json > conf.json

#circus
cd /home/taiga
git clone https://github.com/circus-tent/circus.git circus

mkdir -p /home/taiga/conf
cat > /home/taiga/conf/circus.ini << EOF
[circus]
check_delay = 5
endpoint = tcp://127.0.0.1:5555
pubsub_endpoint = tcp://127.0.0.1:5556
statsd = true

[watcher:taiga]
working_dir = /home/taiga/taiga-back
cmd = gunicorn
args = -w 3 -t 60 --pythonpath=. -b 127.0.0.1:8001 taiga.wsgi
uid = taiga
numprocesses = 1
autostart = true
send_hup = true
stdout_stream.class = FileStream
stdout_stream.filename = /home/taiga/logs/gunicorn.stdout.log
stdout_stream.max_bytes = 10485760
stdout_stream.backup_count = 4
stderr_stream.class = FileStream
stderr_stream.filename = /home/taiga/logs/gunicorn.stderr.log
stderr_stream.max_bytes = 10485760
stderr_stream.backup_count = 4

[env:taiga]
PATH = /home/taiga/.virtualenvs/taiga/bin:$PATH
TERM=rxvt-256color
SHELL=/bin/bash
USER=taiga
LANG=en_US.UTF-8
HOME=/home/taiga
PYTHONPATH=/home/taiga/.virtualenvs/taiga/lib/python3.5/site-packages
EOF

mkdir -p /home/taiga/logs
touch /home/taiga/logs/gunicorn.stdout.log
touch /home/taiga/logs/gunicorn.stderr.log

#circus start
cd /home/taiga/circus/
python3.5 setup.py install
ln -s /opt/python3.5/bin/circusd /usr/local/bin/circusd
systemctl start circus.service

#nginx
cat > /etc/yum.repos.d/nginx.repo << 'EOF'
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=0
enabled=1
EOF
yum install -y nginx

cat > /etc/nginx/conf.d/taiga.conf << 'EOF'
server {
    listen 80 default_server;
    server_name _;

    large_client_header_buffers 4 32k;
    client_max_body_size 50M;
    charset utf-8;

    access_log /home/taiga/logs/nginx.access.log;
    error_log /home/taiga/logs/nginx.error.log;

    # Frontend
    location / {
        root /home/taiga/taiga-front-dist/dist/;
        try_files $uri $uri/ /index.html;
    }

    # Backend
    location /api {
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:8001/api;
        proxy_redirect off;
    }

    # Django admin access (/admin/)
    location /admin {
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:8001$request_uri;
        proxy_redirect off;
    }

    # Static files
    location /static {
        alias /home/taiga/taiga-back/static;
    }

    # Media files
    location /media {
        alias /home/taiga/taiga-back/media;
    }
}
EOF
systemctl restart nginx

chown -R taiga:taiga /home/taiga/
chmod o+x /home/taiga/

#run
su taiga -c "python3.5 /home/taiga/taiga-back/manage.py runserver 0.0.0.0:8000 &"