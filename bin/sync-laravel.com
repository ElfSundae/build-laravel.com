#!/bin/sh

ROOT=$(pwd)"/laravel.com"

usage()
{
    script=$(basename $0)
    cat <<EOT
Sync local mirror of https://laravel.com

Usage: $script [<webroot>] [<options>]

Options:
    --skip-docs     Skip building Laravel docs
    --skip-api      Skip building Laravel api
    -c|--clean      Clean webroot
    -h|--help       Show this help
EOT
}

exit_if_error()
{
    [ $? -eq 0 ] || exit $?
}

update_repo()
{
    if ! [[ -d "$ROOT" ]]; then
        git clone git://github.com/laravel/laravel.com.git "$ROOT"
    else
        git -C "$ROOT" reset --hard
        git -C "$ROOT" pull origin master
    fi

    exit_if_error
}

clean_repo()
{
    if [[ -d "$ROOT" ]]; then
        git -C "$ROOT" clean -dfx
    fi
}

update_app()
{
    cd "$ROOT"

    echo "composer install..."
    # rm -rf vendor
    composer install -q
    if ! [[ -f ".env" ]]; then
        echo "APP_KEY=" > .env
        php artisan key:generate
    fi
    exit_if_error

    echo "npm install..."
    # rm -rf node_modules
    npm install &>/dev/null
    exit_if_error

    echo "gulp --production..."
    gulp --production &>/dev/null
    exit_if_error
}

build_docs()
{
    echo "Updating docs..."

    cd "$ROOT"

    for version in 4.2 5.0 5.1 5.2 5.3 5.4 5.5 master; do
        if ! [[ -d "resources/docs/$version" ]]; then
            git clone git://github.com/laravel/docs.git --single-branch --branch=$version resources/docs/$version -q
        fi
    done

    docs=$(cat build/docs.sh)
    find="/home/forge/laravel.com"
    replace="\"$ROOT\""
    docs=${docs//$find/$replace}
    eval "$docs"
    exit_if_error
}

build_api()
{
    echo "Building API..."

    cd "$ROOT/build/sami"
    rm -rf vendor
    rm -rf composer.lock
    composer require sami/sami:dev-master -q
    exit_if_error

    cd "$ROOT"

    api=$(cat build/api.sh)
    find="/home/forge/laravel.com"
    replace="\"$ROOT\""
    api=${api//$find/$replace}
    eval "$api"
    exit_if_error

    git checkout composer.json composer.lock
}

CLEAN_REPO=0
SKIP_DOCS=0
SKIP_API=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--clean)
            CLEAN_REPO=1
            shift
            ;;
        --skip-docs)
            SKIP_DOCS=1
            shift
            ;;
        --skip-api)
            SKIP_API=1
            shift
            ;;
        *)
            ROOT=${1%/}
            shift
            ;;
    esac
done

if [[ $CLEAN_REPO != 0 ]]; then
    clean_repo
    exit 0;
fi

update_repo
update_app

[[ $SKIP_DOCS == 0 ]] && build_docs
[[ $SKIP_API == 0 ]] && build_api
