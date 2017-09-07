#!/bin/sh

VER="v1.1 - https://github.com/ElfSundae/sync-laravel.com"

usage()
{
    script=$(basename $0)
    cat <<EOT
Sync local mirror of laravel.com website.
$VER

Usage: $script <webroot> [<options>]

Options:
    upgrade         Upgrade this script
    status          Check webroot and docs status
    skip-docs       Skip building docs
    skip-api        Skip building api documentation
    clean           Clean webroot
    -v, --version   Print version of this script
    -h, --help      Show this help
EOT
}

exit_if_error()
{
    [ $? -eq 0 ] || exit $?
}

exit_with_error()
{
    if [[ $# > 0 ]]; then
        echo "$@"
    fi

    echo "\nUse -h to see usage"
    exit 1
}

fullpath()
{
    pushd "$1" > /dev/null
    fullpath=`pwd -P`
    popd > /dev/null
    echo "$fullpath"
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

    ROOT=$(fullpath "$ROOT")
}

clean_repo()
{
    if [[ -d "$ROOT" ]]; then
        git -C "$ROOT" clean -dfx
    fi
}

check_git_status()
{
    cd "$1"
    echo "=> $1"
    git fetch
    exit_if_error

    headRev=$(git rev-parse --short HEAD)
    remoteRev=$(git rev-parse --short @{u})
    if [[ $headRev == $remoteRev ]]; then
        echo "Already up-to-date."
    else
        echo "[$headRev...$remoteRev]"
    fi
}

check_status()
{
    if ! [[ -d "$ROOT" ]]; then
        echo "$ROOT does not exist."
        exit 1
    fi

    check_git_status "$ROOT"
    git -C "$ROOT" status

    for version in 4.2 5.0 5.1 5.2 5.3 5.4 5.5 master; do
        check_git_status "$ROOT/resources/docs/$version"
    done
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

    # Fix Sami failure: always use the master code because dev-master
    # from Packagist may not be the newest.
    # https://github.com/FriendsOfPHP/Sami/issues/294
    cd "$ROOT/build/sami"
    rm -rf vendor
    rm -rf composer.lock
    composer config repositories.sami '{"type":"vcs","url":"https://github.com/FriendsOfPHP/Sami","no-api":true}'
    composer require sami/sami:dev-master -q
    exit_if_error

    cd "$ROOT"

    # Create "public/api" directory to make `cp -r build/sami/build/* public/api`
    # in `api.sh` work.
    rm -rf public/api
    mkdir public/api

    api=$(cat build/api.sh)
    find="/home/forge/laravel.com"
    replace="\"$ROOT\""
    api=${api//$find/$replace}
    eval "$api"
    exit_if_error

    git checkout composer.json composer.lock
}

upgrade_me()
{
    url="https://raw.githubusercontent.com/ElfSundae/sync-laravel.com/master/sync-laravel.com"
    to=$(fullpath `dirname $0`)/`basename $0`
    wget "$url" -O "$to"
    exit_if_error
    chmod +x "$to"
}

while [[ $# > 0 ]]; do
    case "$1" in
        upgrade)
            UPGRADE_ME=1
            shift
            ;;
        status)
            CHECK_STATUS=1
            shift
            ;;
        skip-docs)
            SKIP_DOCS=1
            shift
            ;;
        skip-api)
            SKIP_API=1
            shift
            ;;
        clean)
            CLEAN_REPO=1
            shift
            ;;
        -v|--version)
            echo "$VER"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$ROOT" ]]; then
                ROOT=${1%/}
            else
                exit_with_error "Unknown argument: $1"
            fi
            shift
            ;;
    esac
done

if [[ -n $UPGRADE_ME ]]; then
    upgrade_me
    exit 0
fi

if [[ -z "$ROOT" ]]; then
    exit_with_error "Missing argument: webroot path"
fi

if [[ -n $CHECK_STATUS ]]; then
    check_status
    exit 0
fi

if [[ -n $CLEAN_REPO ]]; then
    clean_repo
    exit 0
fi

update_repo
update_app

[[ -z $SKIP_DOCS ]] && build_docs
[[ -z $SKIP_API ]] && build_api

echo "Completed successfully!"
