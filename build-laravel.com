#!/bin/sh

VER="1.13.0"
DOC_VERSIONS=(4.2 5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8 6.x 7.x 8.x master)

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
        git -C "$ROOT" clean -dfx -e "/.env"
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
    composer install --no-dev -o --ignore-platform-req=php --no-interaction -q
    exit_if_error

    if ! [[ -f ".env" ]]; then
        echo "APP_KEY=" > .env
        php artisan config:clear -q
        php artisan key:generate
        exit_if_error
    fi

    php artisan clear-compiled
    php artisan view:clear

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
    npm run production &>/dev/null
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
            git -C "$path" clean -dfx -q
            git -C "$path" pull origin "$version"
        fi
    done

    # This may be legacy code, see CacheResponse middleware
    php artisan docs:clear-cache
}

build_api()
{
    echo "Building API documentation..."

    doctum=$ROOT/build/doctum

    cd "$doctum"

    if ! [[ -d laravel ]]; then
        git clone git://github.com/laravel/framework.git laravel
    else
        git -C laravel reset --hard -q
        git -C laravel clean -dfx
        git -C laravel fetch
    fi

    apiDir=$ROOT/public/api
    apiVerFile=$apiDir/version.txt
    apiOldVer=`cat "$apiVerFile" 2>/dev/null`
    apiVer=$(git -C "laravel" log -1 --format="%H" --all)

    if [[ -z $FORCE ]] && [[ -d "$apiDir" ]] && [[ $apiOldVer == $apiVer ]]; then
        return
    fi

    if [[ 1 ]]; then
        composer install
    else
        composer require code-lts/doctum --prefer-stable --prefer-dist
        exit_if_error
        git checkout composer.json
        git checkout composer.lock &>/dev/null
    fi

    rm -rf build
    rm -rf cache
    ./vendor/bin/doctum.php update doctum.php

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
        text=${text//cdnjs.cloudflare.com/cdnjs.cat.net}
        # text=${text//fonts.googleapis.com/fonts.cat.net}
        # text=${text//fonts.gstatic.com/gstatic.cat.net}
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

cachesite_content()
{
    cat <<'EOF'
<?php

namespace App;

use Illuminate\Support\Str;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Facade;
use Illuminate\Support\Facades\Artisan;
use Symfony\Component\HttpFoundation\Request as SymfonyRequest;

class CacheSite
{
    const CACHE_DIR = 'storage/site-cache';

    public function cache()
    {
        // Clear the parsed doc markdown cache
        Artisan::call('cache:clear');

        $routeUrls = array_map('url', $this->getRoutePaths());

        $this->saveResponseForUrls($routeUrls);

        $this->saveSitemap(array_merge($routeUrls, $this->getApiUrls()));
    }

    protected function getRoutePaths()
    {
        $routes = [];

        // Routes
        foreach (Route::getRoutes() as $route) {
            if (! Str::is('docs*', $route->uri())) {
                $routes[] = $route->uri();
            }
        }

        $docVersions = array_keys(Documentation::getDocVersions());

        // Docs index pages
        foreach ($docVersions as $version) {
            $routes[] = 'docs/'.$version;
        }

        // Docs content pages
        $docFiles = glob(resource_path('docs/{*,*/*}/*.md'), GLOB_BRACE) ?: [];
        $docsRoot = resource_path('docs/');
        foreach ($docFiles as $path) {
            if(! mb_check_encoding(pathinfo($path, PATHINFO_BASENAME), 'ASCII')) {
                continue;
            }

            $path = Str::replaceFirst($docsRoot, '', $path);
            $path = Str::replaceLast('.md', '', $path);
            $segments = explode('/', $path);

            if (in_array($segments[0], $docVersions, true)) {
                array_unshift($segments, 'docs');
            } else {
                $locale = array_shift($segments);
                array_unshift($segments, $locale, 'docs');
            }

            $routes[] = implode('/', $segments);
        }

        // Other pages
        $routes[] = '404';

        $result = $routes;

        // Localized pages
        foreach (config('locales', []) as $locale) {
            foreach ($routes as $path) {
                if (explode('/', $path)[0] !== $locale) {
                    $result[] = trim($locale.'/'.trim($path, '/'), '/');
                }
            }
        }

        return array_filter(array_unique($result));
    }

    protected function getApiUrls()
    {
        return array_map(function ($version) {
            return url("api/$version/");
        }, array_keys(Documentation::getDocVersions()));
    }

    protected function saveResponseForUrls($urls)
    {
        $currentRequest = app('request');

        foreach ($urls as $url) {
            $request = Request::createFromBase(SymfonyRequest::create($url));
            $response = app('Illuminate\Contracts\Http\Kernel')->handle($request);

            // Restore current request
            app()->instance('request', $currentRequest);
            Facade::clearResolvedInstance('request');

            // Note: use $url (not $request->path()) to get cache path
            $path = urldecode(parse_url($url, PHP_URL_PATH) ?: '/');
            $filename = (trim($path, '/') ?: 'index').'.html';

            $this->saveFile($filename, $response->getContent());
        }

        echo 'Cached '.count($urls).' pages.'.PHP_EOL;
    }

    protected function saveSitemap($urls)
    {
        $filename = 'sitemap.txt';
        $this->saveFile($filename, implode(PHP_EOL, $urls));
        echo 'Sitemap: '.$this->getCacheUrl($filename).PHP_EOL;
    }

    protected function saveFile($filename, $content)
    {
        $path = $this->getCachePath($filename);

        // If the file did not change, keeping the original file for
        // cache-control usage, i.e. 304 response.
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
        return public_path(static::CACHE_DIR.$this->prefixedPath($path));
    }

    protected function getCacheUrl($path = '')
    {
        return url(static::CACHE_DIR.$this->prefixedPath($path));
    }

    protected function prefixedPath($path = '')
    {
        $path = trim($path, '/');

        return $path ? '/'.$path : '';
    }
}

EOF
}

cache_site()
{
    echo "Creating website cache..."

    cd "$ROOT"

    cacheSiteFile="$ROOT/app/CacheSite.php"
    if [[ -f "$cacheSiteFile" ]]; then
        unset cacheSiteFile
    else
        echo "$(cachesite_content)" > "$cacheSiteFile"
    fi

    # Register "cache-site" artisan command if it is not existed.
    php artisan cache-site -h &>/dev/null
    if [[ $? != 0 ]]; then
        kernel="$ROOT/app/Console/Kernel.php"
        kernelContent=$(cat "$kernel")
        from=$(cat <<'EOT'
    protected function commands()
    {
EOT
)
        to=$(cat <<'EOT'

        $this->command('cache-site', function () {
            app()->call('App\CacheSite@cache');
        });
EOT
)
        kernelContent=${kernelContent/"$from"/"$from$to"}
        echo "$kernelContent" > "$kernel"
    fi

    php artisan cache-site

    [[ -n "$cacheSiteFile" ]] && rm -rf "$cacheSiteFile"
    [[ -n "$kernel" ]] && git checkout "$kernel"
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
