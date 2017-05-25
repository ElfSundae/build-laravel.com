#!/bin/sh

## Sync laravel.com website.

root=/data/www/laravel.com

if ! [[ -d "$root" ]]; then
    git clone git@github.com:laravel/laravel.com.git "$root"
fi

cd "$root"

git pull origin master

for version in 5.0 5.1 5.2 5.3 5.4 master; do
    if ! [[ -d "resources/docs/$version" ]]; then
        git clone git@github.com:laravel/docs.git --single-branch --branch=$version --verbose resources/docs/$version
    fi
done

composer install

# rm -rf node_modules
npm install
gulp --production

docs=$(cat build/docs.sh)
docs=${docs//home\/forge/data\/www}
eval "$docs"

composer global require sami/sami:dev-master

old_sami_content=$(cat build/sami/sami.php)
new_sami_content=${old_sami_content/require __DIR__/require \'$HOME\/.composer\'}
echo "$new_sami_content" > build/sami/sami.php
api=$(cat build/api.sh)
api=${api//home\/forge/data\/www}
api=${api//\${sami\}\/vendor\/bin\/sami.php/php $HOME\/.composer\/vendor\/bin\/sami.php}
eval "$api"
echo "$old_sami_content" > build/sami/sami.php

git reset --hard
