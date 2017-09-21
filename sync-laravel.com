#!/bin/sh

VER="v1.17 - https://github.com/ElfSundae/sync-laravel.com"

DOC_VERSIONS=(4.2 5.0 5.1 5.2 5.3 5.4 5.5 master)

usage()
{
    script=$(basename "$0")
    cat <<EOT
Sync local mirror of laravel.com website.
$VER

Usage: $script <webroot> [<options>]

Options:
    upgrade             Upgrade this script
    status              Check status of webroot and docs
    --root-url=URL      Set the root URL of website, APP_URL environment variable
    skip-docs           Skip updating docs
    skip-api            Skip building api documentation
    skip-update-app     Skip updating app: pull repository, install PHP and Node
                        packages, process views, compile assets
    local-cdn           Download static files from CDN, and host them locally
    --font-format=FMT   Use FMT when downloading Google Fonts
                        Supported: eot, ttf, svg, woff, woff2
                        Default is woff2
    --title=TXT         Replace page title to TXT
    china-cdn           Replace CDN hosts with China mirrors
    --gaid=GID          Replace Google Analytics tracking ID with GID
    remove-ga           Remove Google Analytics
    remove-ads          Remove advertisements
    cache               Create website cache
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
        git clone git://github.com/laravel/laravel.com.git "$ROOT"
    else
        git -C "$ROOT" reset --hard
        git -C "$ROOT" pull #origin master
    fi
    exit_if_error

    ROOT=$(fullpath "$ROOT")

    cd "$ROOT"

    process_source

    echo "Installing PHP packages..."
    composer install --no-dev --no-interaction -q
    exit_if_error

    if ! [[ -f ".env" ]]; then
        echo "APP_KEY=" > .env
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

update_docs()
{
    echo "Updating docs..."

    cd "$ROOT"

    for version in "${DOC_VERSIONS[@]}"; do
        path="resources/docs/$version"
        if ! [[ -d "$path" ]]; then
            git clone git://github.com/laravel/docs.git --single-branch --branch="$version" "$path"
        else
            git -C "$path" reset --hard -q
            git -C "$path" pull origin "$version"
        fi
    done

    # Replace laravel.com URL in docs.
    # NOTE: `sed -i` is different in macOS and GNU system.
    find resources/docs -name "*.md" \
        -exec sed -i.bak "s#https\{0,1\}://laravel.com/#${ROOT_URL}/#g" "{}" \;
    find resources/docs -name "*.md.bak" -exec rm -rf "{}" \;

    # Clear parsed markdown to make new URL work
    php artisan cache:clear

    # This maybe legacy code, see CacheResponse middleware
    # php artisan docs:clear-cache
}

build_api()
{
    echo "Building API documentation..."

    sami=$ROOT/build/sami

    cd "$sami"

    if ! [[ -d laravel ]]; then
        git clone git://github.com/laravel/framework.git laravel
    else
        git -C laravel fetch
    fi

    apiDir=$ROOT/public/api
    apiVerFile=$apiDir/version.txt
    apiOldVer=`cat "$apiVerFile" 2>/dev/null`
    apiVer=$(git -C "laravel" log -1 --format="%H" --all)

    if [[ $apiOldVer == $apiVer ]] && [[ -z $FORCE ]]; then
        return
    fi

    composer update
    exit_if_error
    git checkout composer.lock

    rm -rf build
    rm -rf cache
    ./vendor/bin/sami.php update sami.php
    exit_if_error

    mkdir -p "$apiDir"
    cp -af build/* "$apiDir"
    echo "$apiVer" > "$apiVerFile"
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
        text=${text//cdnjs.cloudflare.com/cdnjs.cat.net}
        text=${text//fonts.googleapis.com/fonts.cat.net}
        text=${text//fonts.gstatic.com/gstatic.cat.net}
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

    # Remove Ads
    if [[ -n $REMOVE_ADS ]]; then
        docsView="$ROOT/resources/views/docs.blade.php"
        docsContent=$(cat "$docsView")
        carbonads=`echo "$docsContent" | grep -E "carbon\.js"`
        docsContent=${docsContent//"$carbonads"}
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

cache_site()
{
    echo "Creating website cache..."

    cd "$ROOT"

    # Add "cache-site" artisan command if it is not existed.
    php artisan cache-site -h &>/dev/null
    if [[ $? != 0 ]]; then
        cacheSiteFile=$ROOT/app/CacheSite.php

        cat <<'EOT' > "$cacheSiteFile"
<?php

namespace App;

use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Request as SymfonyRequest;

class CacheSite
{
    public function cache()
    {
        $routeUrl = array_map('url', $this->getRoutePath());

        foreach ($routeUrl as $url) {
            $request = \Request::createFromBase(SymfonyRequest::create($url));
            $response = app('Illuminate\Contracts\Http\Kernel')->handle($request);
            $this->saveResponse($request, $response);
        }

        $this->saveFile('sitemap.txt', implode(PHP_EOL, array_merge(
            $routeUrl, $this->getApiUrl()
        )));
    }

    protected function getRoutePath()
    {
        $result = [];

        foreach (\Route::getRoutes() as $route) {
            if (! starts_with($route->uri(), 'docs')) {
                $result[] = $route->uri();
            }
        }

        $resourcePath = resource_path();
        foreach (\File::directories($resourcePath.'/docs') as $dir) {
            $result[] = Str::replaceFirst($resourcePath.'/', '', $dir);

            if ($files = glob($dir.'/*.md')) {
                foreach($files as $file) {
                    $file = Str::replaceFirst($resourcePath.'/', '', $file);
                    $file = Str::replaceLast('.md', '', $file);
                    $result[] = $file;
                }
            }
        }

        return array_merge($result, ['404']);
    }

    protected function getApiUrl()
    {
        $result = [];

        foreach (\File::directories(public_path('api')) as $dir) {
            $result[] = url(Str::replaceFirst(public_path(), '', $dir)).'/';
        }

        return $result;
    }

    protected function saveResponse($request, $response)
    {
        $this->saveFile(
            (trim($request->decodedPath(), '/') ?: 'index').'.html',
            $response->getContent()
        );
    }

    protected function saveFile($filename, $content)
    {
        $path = $this->getCachePath($filename);

        if (file_exists($path) && md5_file($path) == md5($content)) {
            return;
        }

        if (! is_dir($dir = pathinfo($path, PATHINFO_DIRNAME))) {
            @mkdir($dir, 0775, true);
        }

        file_put_contents($path, $content);
    }

    protected function getCachePath($path = '')
    {
        return public_path('storage/site-cache'.($path ? '/'.trim($path, '/') : $path));
    }
}
EOT

        # Register command
        kernel="$ROOT/app/Console/Kernel.php"
        kernelContent=$(cat "$kernel")
        from="\$this->command('docs:index'"
        to=$(cat <<'EOT'
$this->command('cache-site', function () {
    app()->call('App\CacheSite@cache');
});
EOT
)
        kernelContent=${kernelContent/"$from"/"$to $from"}
        echo "$kernelContent" > "$kernel"
    fi

    php artisan cache:clear -q
    php artisan cache-site

    if [[ -n "$cacheSiteFile" ]]; then
        rm -rf "$cacheSiteFile"
        git checkout "$kernel"
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

echo "Completed successfully!"
