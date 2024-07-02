# firefox-sync

The purpose of this repository is to provide a docker-compose that can be used to self host what otherwise Firefox sync would send to Mozilla's servers.

## Disclaimer

- ⚠️ The project is under development
- ⚠️ Expect bugs, breaking changes and headache
- ⚠️ **This is not endorsed or supported by Mozilla in any way or form**
- ⚠️ **Do not solely relay on this project to store your bookmarks, passwords and/or other important items**

## Security considerations

- syncstorage-rs does NOT support account allowlisting. This means that ANY person that has network access to your server can use it. Possible solutions:
  - implement the feature directly in server
  - add the entire rest of the Mozilla stack so that authentication is performed and validated locally

## Background

Mozilla's server side components are open source and Firefox allows to easily change the official endpoints.
[Some documentation](https://mozilla-services.readthedocs.io/en/latest/index.html) is provided to install the each component on your own server but this is neither offically supported or very well maintened. Furthermore, there are no official Docker images that can be used to avoid installing everything manually; all the instructions and artifacts provided are focused on setting up a developer environment rather than a production self hosted service. For example, `syncstorage-rs` has a [docker release on docker-hub](https://hub.docker.com/r/mozilla/syncstorage-rs/) but it is targeted to work exclusively with Google Spanner which is what Mozilla uses to provide the service.

## Content and scope of this project
- GitHub workflows to create docker images as vanilla as possible from Mozilla's code
- Docker compose to setup required component to self host Mozilla sync components
- examples to configure other parts of the infrastructure
- instructions to setup your browser to use the self hosted infrastructure

### Docker images currently published
All the images are updated weekly to the latest tag available from Mozilla's official repositories
- [ghcr.io/porelli/firefox-sync:syncstorage-rs-mysql-latest](https://github.com/porelli/firefox-sync/pkgs/container/firefox-sync/versions)
  - source: https://github.com/mozilla-services/syncstorage-rs
  - code changes: none
  - compile options: built to use MySQL as backend database
  - GitHub [workflow](/.github/workflows/syncstorage-rs.yml) and [logs](https://github.com/porelli/firefox-sync/actions/workflows/syncstorage-rs.yml)

## Server setup

1. clone this repositoy
1. copy [.env-example](.env-example) into `.env` (including the dot at the beginning of the file)
1. update the `.env` file
   1. replace "REPLACE_WITH_SOMETHING_SECURE" with adequate passwords
   1. replace "REPLACE_WITH_YOUR_DOMAIN" with the domain you own and intend to use for the syncstorage service
1. setup your reverse proxy server
   1. if you use nginx, check the [syncstorage-rs.conf](/config/nginx/syncstorage-rs.conf) as example
1. start docker compose: `docker compose up`
1. OPTIONAL: Install the systemd service (see [firefox-sync.service](/config/systemd/syncstorage-rs.service)) and enable it
   - all the containers are alredy set to restart automatically; stopping Docker (for example when you shutdown your computer) will automatically stop all the services gracefully and restart them once Docker is starting again

## Firefox setup

**Pre-requisite**: if you already logged into your Firefox account you need to temporarily disconnect it

The below examples assume your server respond to this domain: `firefox-sync.example.com`

### Desktop

1. point a browser tab to `about:config` and search for `identity.sync.tokenserver.uri`
1. Change it from the default to `https://firefox-sync.example.com/1.0/sync/1.5`
1. Log in to Firefox and start syncing.

### Android

1. go to App Menu `⋮` > `Settings` > `About Firefox` and click the logo 5 times. You should see a `debug menu enabled` notification
1. go back to the main setting menu and you will see `Sync Debug` at the top, just under the `Syncronize and save your data` box. Tap on it
1. Tap on `Custom Sync server` and set it to `https://firefox-sync.example.com/1.0/sync/1.5`
1. Log in to Firefox and start syncing.

### iOS

1. go to App Menu `≡` > `Settings` and tap 5 times on the version number (i.e.: `Firefox 127.1 (42781)`) towards the bottom
1. go back at the top of the main setting menu and you will see `Advanced Sync Settings` at the top, just under the `Sync and Save Data`. Tap on it
1. Activate `Use Custom FxA Content Server` and set `Custom Account Content Server URI` to `https://firefox-sync.example.com/1.0/sync/1.5`
1. Log in to Firefox and start syncing.

## Credits
- [Mozilla](https://www.mozilla.org/) for [Firefox](https://www.mozilla.org/firefox) and opensourcing all their software, incuding the backend
- [jeena](https://github.com/jeena) for [fxsync-docker](https://github.com/jeena/fxsync-docker) which is the inspiration for this project