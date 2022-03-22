#!/bin/sh

VER="1.17.0"
DOC_VERSIONS=(4.2 5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 6.x 7.x 8.x 9.x master)

usage()
{
    script=$(basename "$0")
    cat <<EOT
Build mirror of Laravel.com
v$VER - https://github.com/ElfSundae/build-laravel.com

Usage: $script <webroot> [options]

Options:
    status              Check status of webroot and docs
    clean               Clean webroot
    local-cdn           Host CDN files locally
    china-cdn           Replace CDN hosts with China mirrors
    remove-ga           Remove Google Analytics
    remove-ads          Remove advertisements
    cache               Create website cache
    skip-docs           Skip updating docs
    skip-api            Skip building API documentation
    skip-update-app     Skip updating app: git-pull repository, install PHP and Node packages,
                        process views, compile assets, etc
    upgrade             Upgrade this script
    --root-url=URL      Set the root URL of website: APP_URL env variable
    --title=TXT         Replace page title to TXT
    --gaid=GID          Replace Google Analytics tracking ID with GID
    --font-format=FMT   Use FMT when downloading Google Fonts, default is woff2
                        Supported: eot, ttf, svg, woff, woff2
    -f, --force         Force build
    -v, --version       Print version of this script
    -h, --help          Show this help
EOT
}

exit_if_error()
{
    code=$?
    if [[ $code -ne 0 ]]; then
        echo "*** Exit with error.";
        exit $code
    fi
}

exit_with_error()
{
    if [[ $# > 0 ]]; then
        echo "$@"
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
        git -C "$ROOT" clean -dffx -e "/.env"
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

process_source()
{
    # Remove unnecessary middlewares
    httpKernel="$ROOT/app/Http/Kernel.php"
    httpKernelContent=$(cat "$httpKernel")
    removeLines=(
        "\App\Http\Middleware\CacheResponse::class,"
        "\App\Http\Middleware\EncryptCookies::class,"
        "\Illuminate\Cookie\Middleware\AddQueuedCookiesToResponse::class,"
        "\Illuminate\Session\Middleware\StartSession::class,"
        "\Illuminate\View\Middleware\ShareErrorsFromSession::class,"
        "\App\Http\Middleware\VerifyCsrfToken::class,"
    )
    for line in "${removeLines[@]}"; do
        httpKernelContent=${httpKernelContent/"$line"/"// $line"}
    done
    echo "$httpKernelContent" > "$httpKernel"
}

update_app()
{
    if ! [[ -d "$ROOT" ]]; then
        git clone https://github.com/ElfSundae/laravel.com.git "$ROOT"
    else
        git -C "$ROOT" reset --hard
        git -C "$ROOT" pull
    fi
    exit_if_error

    ROOT=$(fullpath "$ROOT")

    cd "$ROOT"

    # process_source

    echo "Installing PHP packages..."
    rm -rf bootstrap/cache/*
    composer install -o --no-dev --no-interaction -q
    exit_if_error

    if ! [[ -f ".env" ]]; then
        cp .env.example .env
        php artisan config:clear -q
        php artisan key:generate
        exit_if_error
    fi

    if [[ -n "$ROOT_URL" ]]; then
        oldAppUrl=$(cat .env | grep "APP_URL=" -m1)
        newAppUrl="APP_URL=$ROOT_URL"
        if [[ -n "$oldAppUrl" ]]; then
            envContent=$(cat .env)
            envContent=${envContent/$oldAppUrl/$newAppUrl}
            echo "$envContent" > .env
        else
            echo "$newAppUrl" >> .env
        fi
    fi

    if ! [[ -d "public/storage" ]]; then
        rm -rf "public/storage"
        php artisan storage:link
        exit_if_error
    fi

    php artisan config:cache
    php artisan route:cache
    php artisan view:cache

    echo "Installing Node packages..."
    if command -v yarn &>/dev/null; then
        yarn
    else
        npm install
    fi
    exit_if_error
}

compile_assets()
{
    cd "$ROOT"

    echo "Compiling Assets..."
    if command -v yarn &>/dev/null; then
        yarn run production
    else
        npm run production
    fi
    exit_if_error
}

update_docs()
{
    echo "Updating docs..."

    cd "$ROOT"

    for version in "${DOC_VERSIONS[@]}"; do
        path="resources/docs/$version"
        if ! [[ -d "$path" ]]; then
            git clone https://github.com/laravel/docs.git --single-branch --branch="$version" "$path"
        else
            git -C "$path" reset --hard -q
            git -C "$path" clean -dfx -q
            git -C "$path" pull origin "$version"
        fi
    done

    # This may be legacy code, see CacheResponse middleware
    # php artisan docs:clear-cache
}

build_api()
{
    echo "Building API documentation..."

    doctum=$ROOT/build/doctum

    cd "$doctum"

    if ! [[ -d laravel ]]; then
        git clone https://github.com/laravel/framework.git laravel
    else
        git -C laravel reset --hard -q
        git -C laravel clean -dfx
        git -C laravel pull
    fi

    apiDir=$ROOT/public/api
    apiVerFile=$apiDir/version.txt
    apiOldVer=`cat "$apiVerFile" 2>/dev/null`
    apiVer=$(git -C "laravel" log -1 --format="%H" --all)

    if [[ -z $FORCE ]] && [[ -d "$apiDir" ]] && [[ $apiOldVer == $apiVer ]]; then
        return
    fi

    if [[ "$(php -r "echo PHP_MAJOR_VERSION;")" -ge "8" ]]; then
        # composer require code-lts/doctum:dev-main
        composer install
    else
        composer update
    fi
    exit_if_error
    git checkout composer.json || true
    git checkout composer.lock || true

    rm -rf build
    rm -rf cache
    ./vendor/bin/doctum.php update doctum.php -v --ignore-parse-errors
    exit_if_error

    rm -rf "$apiDir"
    mkdir "$apiDir"
    cp -af build/* "$apiDir"
    echo "$apiVer" > "$apiVerFile"
    rm -rf build
    rm -rf cache
}

upgrade_me()
{
    url="https://raw.githubusercontent.com/ElfSundae/build-laravel.com/master/build-laravel.com"
    to="$(fullpath $(dirname "$(realpath "$0")"))/$(basename "$0")"
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

    extension="auto"
    if [[ -n $1 ]]; then
        extension=.$1
        shift
    fi
    if [[ $extension == "auto" ]]; then
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
        text=${text//cdnjs.cloudflare.com/cdnjs.loli.net}
        text=${text//fonts.googleapis.com/fonts.loli.net}
        text=${text//fonts.gstatic.com/gstatic.loli.net}
    fi

    echo "$text"
}

process_views()
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
        appContent=${appContent//"$original"/"$TITLE"}
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
        appContent=${appContent/"$from"/"// $from"}
        echo "$appContent" > "$appView"
    fi

    # Remove typography style files: https://cloud.typography.com/7737514/7707592/css/fonts.css
    typography=`echo "$appContent" | grep -E "typography\.com"`
    appContent=${appContent//"$typography"}
    echo "$appContent" > "$appView"

    # Remove Ads
    if [[ -n $REMOVE_ADS ]]; then
        docsView="$ROOT/resources/views/docs.blade.php"
        docsContent=$(cat "$docsView")
        carbonads=`echo "$docsContent" | grep -E "carbon\.js"`
        docsContent=${docsContent//"$carbonads"}
        echo "$docsContent" > "$docsView"
    fi

    # Host external assets
    # marketingView="$ROOT/resources/views/marketing.blade.php"
    # marketingContent=$(cat "$marketingView")
    # external=`echo "$marketingContent" | grep -o -E "https.+ui-preview\.png"`
    # echo "Downloading $external"
    # filename=$(download "$external")
    # if [[ "$filename" ]]; then
    #     marketingContent=${marketingContent/$external/\/$filename}
    #     echo "$marketingContent" > "$marketingView"
    # fi
}

cache_site()
{
    echo "Creating website cache..."

    cd "$ROOT"
    php artisan cache-site
}

###############################################################################
###############################################################################

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
        --root-url=*)
            ROOT_URL=`echo $1 | sed -e 's/^[^=]*=//g'`
            ROOT_URL=${ROOT_URL%/}
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
        skip-update-app)
            SKIP_UPDATE_APP=1
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
        cache)
            CACHE=1
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
elif [[ -d "$ROOT" ]]; then
    ROOT=$(fullpath "$ROOT")
fi

if [[ -n $CHECK_STATUS ]]; then
    check_status
    exit 0
fi

if [[ -n $CLEAN_REPO ]]; then
    clean_repo
    exit 0
fi

START_TIME=$SECONDS

if [[ -z $SKIP_UPDATE_APP ]]; then
    update_app
    process_views
    compile_assets
fi

if ! [[ -d "$ROOT" ]]; then
    exit_with_error "$ROOT does not exist."
fi

[[ -z $SKIP_DOCS ]] && update_docs
[[ -z $SKIP_API ]] && build_api
[[ -n $CACHE ]] && cache_site

ELAPSED_TIME=$(($SECONDS - $START_TIME))

echo "*** Done in $(($ELAPSED_TIME/60)) min $(($ELAPSED_TIME%60)) sec."
