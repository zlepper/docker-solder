#!/bin/sh

echo "Waiting for postgres to start"
sleepTime=5s
until gosu postgres pg_isready 2>/dev/null; do
  >&2 echo "Postgres is unavailable - sleeping for $sleepTime"
  sleep $sleepTime
done
echo "Postgres started"

: ${POSTGRES_USER:="postgres"}
: ${POSTGRES_DB:=$POSTGRES_USER}

mkdir /var/www/technicsolder/app/storage/meta \
      /var/www/technicsolder/app/storage/views \
      /var/www/technicsolder/app/storage/sessions \
      /var/www/technicsolder/app/storage/resources \
      /var/www/technicsolder/app/storage/logs \
      /var/www/technicsolder/app/storage/github-api-cache \
      /var/www/technicsolder/app/storage/debugbar \
      /var/www/technicsolder/app/storage/cache

repoUrl="http://$REPO_HOST/"
echo "$repoUrl" 
### Solder setup
echo "Configuring solder"
cd /var/www/technicsolder
# Change to use postgres for the database
sed -i.bak -E "s!('default' => )'\w+'!\1'pgsql'!g" app/config/database.php
sed -i.bak -E "s!('database' => )'\w+'!\1'$POSTGRES_DB'!" app/config/database.php
sed -i.bak -E "s!('username' => )'\w+'!\1'$POSTGRES_USER'!" app/config/database.php
sed -i.bak -E "s!('password' => )''!\1'$POSTGRES_PASSWORD'!" app/config/database.php
# Setup file storage
sed -i.bak -E "s!('repo_location' => )''!\1'/var/www/repo.solder/'!" app/config/solder.php
sed -i.bak -E "s!('mirror_url' => )''!\1'$REPO_HOST'!" app/config/solder.php
# Setup the solder app
sed -i.bak -E "s!('url' => )'http://solder\.app:8000'!\1'$repoUrl'!" app/config/app.php
# Hack for php7.1 not liking mcrypt
sed -i.bak -E "2s/\s?/error_reporting(E_ALL ^ E_DEPRECATED);/" app/config/app.php
# enable debug mode by default
sed -i.bak "s|'debug' => false|'debug' => true|g" /var/www/technicsolder/app/config/app.php


chmod -R 777 ./app/storage
chmod -R 777 /var/www/technicsolder/public

echo "Running php artisan migrate:install"
# Setup the database data
php artisan migrate:install
echo "Running actual migration"
php artisan --force migrate

# Start php
mkdir /var/run/php
sed -i.bak "s|;*daemonize\s*=\s*yes|daemonize = yes|g" /etc/php7/php-fpm.conf
sed -i.bak "s|;*listen\s*=\s*127.0.0.1:9000|listen = /var/run/php/php-fpm.sock|g" /etc/php7/php-fpm.d/www.conf
sed -i.bak "s|;*listen.owner\s*=\s*nobody|listen.owner = nginx|g" /etc/php7/php-fpm.d/www.conf
sed -i.bak "s|;*listen.group\s*=\s*nobody|listen.group = nginx|g" /etc/php7/php-fpm.d/www.conf
/usr/sbin/php-fpm7

# Setup solder website
mkdir /var/log/nginx/technicsolder
mkdir /run/nginx
sed -i.bak -E "s!ENV_SOLDER_HOST!$SOLDER_HOST!g" /etc/nginx/conf.d/technicsolder.conf

## Setup file repo
# Create user
mkdir /var/www/repo.solder
chmod -R 777 /var/www/repo.solder
# Setup file webserver
mkdir /var/log/nginx/repo.solder
sed -i.bak -E "s!ENV_REPO_HOST!$REPO_HOST!g" /etc/nginx/conf.d/repo.conf

## Setup GFS
gfs -persist -username "$REPO_USER" -password "$REPO_PASSWORD" -serve /var/www/repo.solder
