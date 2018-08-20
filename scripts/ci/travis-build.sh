#!/bin/sh
before_install() {
    unset CC

    # We want to always allow newer versions of packages when building on GHC HEAD
    CABALARGS=""
    if [ "x$GHCVER" = "xhead" ]; then CABALARGS=--allow-newer; fi

    # Download and unpack the stack executable
    export PATH=/opt/ghc/$GHCVER/bin:/opt/cabal/$CABALVER/bin:$HOME/.local/bin:/opt/alex/$ALEXVER/bin:/opt/happy/$HAPPYVER/bin:$HOME/.cabal/bin:$PATH
    mkdir -p ~/.local/bin
    
    if [ `uname` = "Darwin" ]
    then
	travis_retry curl --insecure -L https://get.haskellstack.org/stable/osx-x86_64.tar.gz | tar xz --strip-components=1 --include '*/stack' -C ~/.local/bin
    else
	travis_retry curl -L https://get.haskellstack.org/stable/linux-x86_64.tar.gz | tar xz --wildcards --strip-components=1 -C ~/.local/bin '*/stack'
    fi
    
    # Use the more reliable S3 mirror of Hackage
    mkdir -p $HOME/.cabal
    echo 'remote-repo: hackage.haskell.org:http://hackage.fpcomplete.com/' > $HOME/.cabal/config
    echo 'remote-repo-cache: $HOME/.cabal/packages' >> $HOME/.cabal/config
}

install() {
    echo "$(ghc --version) [$(ghc --print-project-git-commit-id 2> /dev/null || echo '?')]"
    if [ -f configure.ac ]; then autoreconf -i; fi
    set -ex
    case "$BUILD" in
	stack)
	    # Add in extra-deps for older snapshots, as necessary
	    #
	    # This is disabled by default, as relying on the solver like this can
	    # make builds unreliable. Instead, if you have this situation, it's
	    # recommended that you maintain multiple stack-lts-X.yaml files.

	    #stack --no-terminal --install-ghc $ARGS test --bench --dry-run || ( \
		#  stack --no-terminal $ARGS build cabal-install && \
		#  stack --no-terminal $ARGS solver --update-config)

	    # Build the dependencies
	    stack --no-terminal --install-ghc $ARGS test --bench --only-dependencies
	    ;;
	cabal)
	    cabal --version
	    travis_retry cabal update

	    # Get the list of packages from the stack.yaml file. Note that
	    # this will also implicitly run hpack as necessary to generate
	    # the .cabal files needed by cabal-install.
	    PACKAGES=$(stack --install-ghc query locals | grep '^ *path' | sed 's@^ *path:@@')

	    cabal install --only-dependencies --enable-tests --enable-benchmarks --force-reinstalls --ghc-options=-O0 --reorder-goals --max-backjumps=-1 $CABALARGS $PACKAGES
	    ;;
    esac
    set +ex

}

script() {
    set -ex
    case "$BUILD" in
	stack)
	    stack --no-terminal $ARGS test --bench --no-run-benchmarks
	    ;;
	cabal)
	    cabal install --enable-tests --enable-benchmarks --force-reinstalls --ghc-options=-O0 --reorder-goals --max-backjumps=-1 $CABALARGS $PACKAGES

	    ORIGDIR=$(pwd)
	    for dir in $PACKAGES
	    do
		cd $dir
		cabal check || [ "$CABALVER" == "1.16" ]
		cabal sdist
		PKGVER=$(cabal info . | awk '{print $2;exit}')
		SRC_TGZ=$PKGVER.tar.gz
		cd dist
		tar zxfv "$SRC_TGZ"
		cd "$PKGVER"
		cabal configure --enable-tests --ghc-options -O0
		cabal build
		if [ "$CABALVER" = "1.16" ] || [ "$CABALVER" = "1.18" ]; then
		    cabal test
		else
		    cabal test --show-details=streaming --log=/dev/stdout
		fi
		cd $ORIGDIR
	    done
	    ;;
    esac
    scripts/ci/build-package.sh curly
    set +ex
}

case "$1" in
    before_install) before_install;;
    script) script;;
    install) install;;
esac
