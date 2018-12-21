You need following modules to start developing:

* Module::Install
* Module::Install::CPANfile
* Module::Install::ReadmeFromPod
* Module::Install::AuthorTests

If you have got Carton installed you can install all required modules via:

    carton install

Make sure you set the PERL5LIB variable afterwards:

    export PERL5LIB=lib:local/lib/perl5
    prove
    perl Makefile.PL && make && make manifest && make dist

By default all live test which require rabbitmq-server to be running are
skipped. If you want to run those tests you need to set the environment
variable BEETLE_LIVE_TEST to true. Then you're expected to have a redis-server
instance running on port 6379 and two rabbitmq-server instances running
on port 5672 and 5673. You can also export BEETLE_START_SERVICES so those
services are automatically started/terminated on each test run for you.
I highly recommend to -not- use this anymore. Instead start the services
manually.

To run integration tests on a vanilla checkout, do this:

    docker network create beetle
    docker run --name rabbit1 --net beetle --rm -d -p 5672:5672 -p 15672:15672 rabbitmq:management
    docker run --name rabbit2 --net beetle --rm -d -p 5673:5673 -p 15673:15673 rabbitmq:management
    docker run --name redis1  --net beetle --rm -d -p 6379:6379 redis

    # Start your environment in a docker container. This is just an example:
    docker run --rm --net beetle -it -v $PWD:/app ubuntu bash
    apt update && apt install -y perl cpanminus libxml2-dev uuid-dev
    cd /app
    cpanm install -n --installdeps --with-develop .

    perl Makefile.PL
    BEETLE_LIVE_TEST=1 make test

    docker stop rabbit1 rabbit2 redis1
    docker network rm beetle
