#!/bin/sh

VER="v1.11 - https://github.com/ElfSundae/sync-laravel.com"

DOC_VERSIONS=(4.2 5.0 5.1 5.2 5.3 5.4 5.5 master)

usage()
{
    script=$(basename $0)
    cat <<EOT
Sync local mirror of laravel.com website.
$VER

Usage: $script <webroot> [<options>]

Options:
    upgrade             Upgrade this script
    status              Check status of webroot and docs
    skip-docs           Skip building docs
    skip-api            Skip building api documentation
    local-cdn           Download static files from CDN, and host them locally
    --font-format=FMT   Use FMT when downloading Google Fonts
                        Supported: eot, ttf, svg, woff, woff2
                        Default format is woff2
    --title=TXT         Replace page title to TXT
    china-cdn           Replace CDN hosts with China mirrors
    --gaid=GID          Replace Google Analytics tracking ID with GID
    remove-ga           Remove Google Analytics
    remove-ads          Remove advertisements
    clean               Clean webroot
    -f, --force         Force build
    --version           Print version of this script
    -h, --help          Show this help
EOT
}

exit_if_error()
{
    [ $? -eq 0 ] || exit $?
}

exit_with_error()
{
    if [[ $# > 0 ]]; then
        echo "$@\n"
    fi

    echo "Use -h to see usage"
    exit 1
}

fullpath()
{
    pushd "$1" > /dev/null
    fullpath=`pwd -P`
    popd > /dev/null
    echo "$fullpath"
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

    for version in "${DOC_VERSIONS[@]}"; do
        check_git_status "$ROOT/resources/docs/$version"
    done
}

update_app()
{
    if ! [[ -d "$ROOT" ]]; then
        git clone git://github.com/laravel/laravel.com.git "$ROOT"
    else
        git -C "$ROOT" reset --hard
        git -C "$ROOT" pull origin master
    fi
    exit_if_error

    ROOT=$(fullpath "$ROOT")

    cd "$ROOT"

    echo "Installing PHP packages..."
    composer install --no-dev --no-interaction -q
    exit_if_error

    if ! [[ -f ".env" ]]; then
        echo "APP_KEY=" > .env
        php artisan key:generate
        exit_if_error
    fi

    if ! [[ -d "public/storage" ]]; then
        php artisan storage:link
        exit_if_error
    fi

    php artisan config:cache
    # php artisan route:cache

    echo "Installing Node packages..."
    type yarn &>/dev/null
    if [[ $? == 0 ]]; then
        yarn &>/dev/null
    else
        npm install &>/dev/null
    fi
    exit_if_error
}

compile_assets()
{
    cd "$ROOT"

    echo "Compiling Assets..."
    gulp --production &>/dev/null
    exit_if_error
}

build_docs()
{
    echo "Updating docs..."

    cd "$ROOT"

    # ------------------------------------
    # Use "build/docs.sh" to build
    # ------------------------------------
    # for version in "${DOC_VERSIONS[@]}"; do
    #     path="resources/docs/$version"
    #     if ! [[ -d "$path" ]]; then
    #         git clone git://github.com/laravel/docs.git --single-branch --branch=$version "$path"
    #     fi
    # done
    #
    # docs=$(cat build/docs.sh)
    # from="/home/forge/laravel.com"
    # to="\"$ROOT\""
    # docs=${docs//$from/$to}
    # eval "$docs"
    # exit_if_error
    # ------------------------------------

    docsChanged=0
    for version in "${DOC_VERSIONS[@]}"; do
        path="resources/docs/$version"
        if ! [[ -d "$path" ]]; then
            git clone git://github.com/laravel/docs.git --single-branch --branch=$version "$path"
            docsChanged=1
        else
            oldRev=$(git -C "$path" rev-parse HEAD)
            git -C "$path" pull origin $version
            newRev=$(git -C "$path" rev-parse HEAD)

            if [[ $oldRev == $newRev ]]; then
                docsChanged=$(( $docsChanged | 0 ))
            else
                docsChanged=$(( $docsChanged | 1 ))
            fi
        fi
    done

    # TODO: Remove this 'if' if you have really known how does the page cache work.
    #
    # Docs page caches are the whole html contents (http response), and they
    # should be removed after docs changed, assets file (view/js/css) changed,
    # it may be used by a HTTP server like Nginx.
    # if [[ $docsChanged != 0 ]]; then
        php artisan docs:clear-cache
        exit_if_error
    # fi
}

build_api()
{
    echo "Building API..."

    sami=${ROOT}/build/sami

    cd "$sami"
    composer update
    exit_if_error
    git checkout composer.lock

    if ! [[ -d "laravel" ]]; then
        git clone git://github.com/laravel/framework.git laravel
    else
        git -C "laravel" reset --hard
        git -C "laravel" clean -dfx
        oldRev=$(git -C "laravel" rev-parse HEAD)
        git -C "laravel" pull
        newRev=$(git -C "laravel" rev-parse HEAD)

        if [[ $oldRev == $newRev ]] && [[ -z $FORCE ]]; then
            return
        fi
    fi

    rm -rf build
    rm -rf cache
    ./vendor/bin/sami.php update sami.php
    exit_if_error

    mkdir -p "$ROOT/public/api"
    cp -af build/* "$ROOT/public/api"
    rm -rf build
    rm -rf cache
}

upgrade_me()
{
    url="https://raw.githubusercontent.com/ElfSundae/sync-laravel.com/master/sync-laravel.com"
    to=$(fullpath `dirname "$0"`)/$(basename "$0")
    wget "$url" -O "$to"
    exit_if_error
    chmod +x "$to"
}

# download url [<extension>|"auto"] [wget parameters]
# return filename in public directory
download()
{
    url=$1
    shift

    extension="__auto__"
    if [[ -n $1 ]]; then
        extension=.$1
        shift
    fi
    if [[ $extension == "__auto__" ]]; then
        extension=.${url##*.}
    fi

    md5=`php -r "echo md5('$url');" 2>/dev/null`
    filename="storage/$md5$extension"
    path="$ROOT/public/$filename"

    if ! [[ -s "$path" ]]; then
        url=${url/#\/\//https:\/\/}
        mkdir -p "$(dirname "$path")"
        wget "$url" -O "$path" -T 15 -q "$@" || rm -rf "$path"
    fi

    if [[ -s "$path" ]]; then
        echo "$filename"
    fi
}

cdn_url()
{
    text=$1

    if [[ -n $CHINA_CDN ]]; then
        text=${text//cdnjs.cloudflare.com/cdnjs.cat.net}
        text=${text//fonts.googleapis.com/fonts.cat.net}
        text=${text//fonts.gstatic.com/gstatic.cat.net}
    fi

    echo "$text"
}

process_source()
{
    appView="$ROOT/resources/views/app.blade.php"
    appContent=$(cat "$appView")

    # Download CDN files and host them locally
    if [[ -n $LOCAL_CDN ]]; then
        echo "Replacing CDNJS with local files..."
        urls=`echo "$appContent" | grep -o -E "[^'\"]+cdnjs\.cloudflare\.com[^'\"]+"`
        while read -r line; do
            filename=$(download "$(cdn_url $line)")
            if [[ "$filename" ]]; then
                appContent=${appContent/$line/\/$filename}
                echo "$appContent" > "$appView"
            fi
        done <<< "$urls"

        echo "Replacing Google Fonts with local files..."
        urls=`echo "$appContent" | grep -o -E "[^'\"]+fonts\.googleapis\.com/css[^'\"]+"`
        while read -r line; do
            # Use different User Agent to download certain format of fonts.
            # Default format is woff2.
            # See https://stackoverflow.com/a/27308229/521946
            if [[ $FONT_FORMAT == "eot" ]]; then
                userAgent="Mozilla/5.0 (compatible; MSIE 8.0; Windows NT 6.1; Trident/4.0; GTB7.4; InfoPath.2; SV1; .NET CLR 3.3.69573; WOW64; en-US)"
            elif [[ $FONT_FORMAT == "ttf" ]]; then
                userAgent="Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10_6_8; de-at) AppleWebKit/533.21.1 (KHTML, like Gecko) Version/5.0.5 Safari/533.21.1"
            elif [[ $FONT_FORMAT == "svg" ]]; then
                userAgent="Mozilla/5.0 (iPhone; U; CPU like Mac OS X; en) AppleWebKit/420+ (KHTML, like Gecko) Version/3.0 Mobile/1C25 Safari/419.3"
            elif [[ $FONT_FORMAT == "woff" ]]; then
                userAgent="Mozilla/5.0 (Windows; U; MSIE 9.0; Windows NT 9.0; en-US))"
            else
                FONT_FORMAT="woff2"
                userAgent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.113 Safari/537.36"
            fi

            url=$(cdn_url $line)"&$FONT_FORMAT"
            filename=$(download "$url" "css" --user-agent="$userAgent")
            if [[ "$filename" ]]; then
                appContent=${appContent/$line/\/$filename}
                echo "$appContent" > "$appView"

                # Download font files
                fontCssPath="$ROOT/public/$filename"
                fontCssContent=$(cat "$fontCssPath")
                fontURLs=`echo "$fontCssContent" | grep -o -E "http[^)]+"`
                while read -r fontLine; do
                    filename=$(download "$(cdn_url $fontLine)")
                    if [[ "$filename" ]]; then
                        fontCssContent=${fontCssContent/$fontLine/\/$filename}
                        echo "$fontCssContent" > "$fontCssPath"
                    fi
                done <<< "$fontURLs"
            fi
        done <<< "$urls"
    fi

    # Replace page title
    if [[ -n "$TITLE" ]]; then
        original="Laravel - The PHP Framework For Web Artisans"
        appContent=${appContent//$original/$TITLE}
        echo "$appContent" > "$appView"
    fi

    # Replace CDN URLs
    appContent=$(cdn_url "$appContent")
    echo "$appContent" > "$appView"

    # Set GA ID
    if [[ -n $GAID ]]; then
        appContent=${appContent//UA-23865777-1/$GAID}
        echo "$appContent" > "$appView"
    fi

    # Remove GA
    if [[ -n $REMOVE_GA ]]; then
        from="s.parentNode.insertBefore(g,s)"
        to="// $from"
        appContent=${appContent/$from/$to}
        echo "$appContent" > "$appView"
    fi

    # Remove Ads
    if [[ -n $REMOVE_ADS ]]; then
        docsView="$ROOT/resources/views/docs.blade.php"
        docsContent=$(cat "$docsView")
        carbonads=`echo "$docsContent" | grep -E "carbon\.js"`
        docsContent=${docsContent//$carbonads}
        echo "$docsContent" > "$docsView"
    fi

    # Host external assets
    marketingView="$ROOT/resources/views/marketing.blade.php"
    marketingContent=$(cat "$marketingView")
    external=`echo "$marketingContent" | grep -o -E "https.+ui-preview\.png"`
    echo "Downloading $external"
    filename=$(download "$external")
    if [[ "$filename" ]]; then
        marketingContent=${marketingContent/$external/\/$filename}
        echo "$marketingContent" > "$marketingView"
    fi
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
        local-cdn)
            LOCAL_CDN=1
            shift
            ;;
        --font-format=*)
            FONT_FORMAT=`echo $1 | sed -e 's/^[^=]*=//g'`
            shift
            ;;
        --title=*)
            TITLE=`echo $1 | sed -e 's/^[^=]*=//g'`
            shift
            ;;
        china-cdn)
            CHINA_CDN=1
            shift
            ;;
        --gaid=*)
            GAID=`echo $1 | sed -e 's/^[^=]*=//g'`
            shift
            ;;
        remove-ga)
            REMOVE_GA=1
            shift
            ;;
        remove-ads)
            REMOVE_ADS=1
            shift
            ;;
        clean)
            CLEAN_REPO=1
            shift
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --version)
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

update_app

process_source
compile_assets

[[ -z $SKIP_DOCS ]] && build_docs
[[ -z $SKIP_API ]] && build_api

echo "Completed successfully!"
