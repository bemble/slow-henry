# Changelog

## [0.7.0](https://github.com/bemble/slow-henry/compare/v0.6.0...v0.7.0) (2026-10-27)


### Features

* index open pull requests (open_pull_requests, bot_pull_requests) ([#43](https://github.com/bemble/slow-henry/issues/43)) ([de00109](https://github.com/bemble/slow-henry/commit/de00109a10e8583c4cf074007a9567fb25fd1489))
* markdown chunking for everything that isn't code ([#39](https://github.com/bemble/slow-henry/issues/39)) ([241023e](https://github.com/bemble/slow-henry/commit/241023e518453e6c5000c5da4d338f67f0e6f3c4))
* max_age for a repo's non-code data (PRs for now) ([#44](https://github.com/bemble/slow-henry/issues/44)) ([0d6ad87](https://github.com/bemble/slow-henry/commit/0d6ad8729f5ad2539c54db4ba7ac345079753153))


### Bug Fixes

* **deps:** bump bandit to 1.14.0 ([#41](https://github.com/bemble/slow-henry/issues/41)) ([942b971](https://github.com/bemble/slow-henry/commit/942b971e1232e56919cf05d8a9e09b3abc124d51))

## [0.6.0](https://github.com/bemble/slow-henry/compare/v0.5.0...v0.6.0) (2026-10-24)


### Features

* configurable Drive label filters in sources.toml ([#35](https://github.com/bemble/slow-henry/issues/35)) ([3158442](https://github.com/bemble/slow-henry/commit/31584424ccc3ae84839ed0a5364a1dcddedb180a))
* Jira projects in sources.toml, API token from the UI, optional fields ([#37](https://github.com/bemble/slow-henry/issues/37)) ([d2d0501](https://github.com/bemble/slow-henry/commit/d2d0501b1c18b9608807eb9992c6726d77b3ff40))
* tabs on the Settings page and in the sources editor, icons in the menu ([#38](https://github.com/bemble/slow-henry/issues/38)) ([99dba8d](https://github.com/bemble/slow-henry/commit/99dba8db597a9a25564cdd8692b944ca205c8caf))

## [0.5.0](https://github.com/bemble/slow-henry/compare/v0.4.0...v0.5.0) (2026-10-24)


### Features

* get_document MCP tool returns Drive doc and Jira issue text ([c8794cd](https://github.com/bemble/slow-henry/commit/c8794cd43b6e95f810111b8db0f6bfc08c9a5922))
* get_document MCP tool returns Drive doc and Jira issue text ([58d2a3c](https://github.com/bemble/slow-henry/commit/58d2a3ce0415753d204a698a78d5379f1f321478))
* index PR authors and reviewers, filter semantic_search by them ([4ce4979](https://github.com/bemble/slow-henry/commit/4ce4979d1d53100ed264668009437cf6bed6eeba))
* index PR authors and reviewers, filter semantic_search by them ([62d6f45](https://github.com/bemble/slow-henry/commit/62d6f45693ea3214685e72cd55e25cdce7297330))


### Bug Fixes

* always redirect Google OAuth to localhost, whatever PHX_HOST says ([7383c4a](https://github.com/bemble/slow-henry/commit/7383c4a52ccb925608736034785b3245155ae8aa))
* always redirect Google OAuth to localhost, whatever PHX_HOST says ([d3f3a36](https://github.com/bemble/slow-henry/commit/d3f3a360ba957173b272d29e9efbdf2495ac4d74))

## [0.4.0](https://github.com/bemble/slow-henry/compare/v0.3.0...v0.4.0) (2026-10-23)


### Features

* show the app version and MCP setup on the Connections page ([1f9c6d5](https://github.com/bemble/slow-henry/commit/1f9c6d5db7ad560af0e78262148bfc96b3d9b467))
* show the app version and MCP setup on the Connections page ([63ca5c4](https://github.com/bemble/slow-henry/commit/63ca5c483eec96598403232a5a2e1ec7a9415e2e))

## [0.3.0](https://github.com/bemble/slow-henry/compare/v0.2.1...v0.3.0) (2026-10-23)


### Features

* edit sources.toml from the UI ([ccaa2ac](https://github.com/bemble/slow-henry/commit/ccaa2acc7b62606f05749236b56525ca85cecd49))

## [0.2.1](https://github.com/bemble/slow-henry/compare/v0.2.0...v0.2.1) (2026-10-23)


### Bug Fixes

* **build:** always prefetch, even when _build has the deps compiled ([4439afe](https://github.com/bemble/slow-henry/commit/4439afe5ee28811bb4d024e9138ea75c19fd7a09))
* **build:** fetch GitHub release artifacts with curl on OTP 29.1 ([3fae967](https://github.com/bemble/slow-henry/commit/3fae967823a7daba43326aaaac981534e7aa6739))
* sync with upstream bbangert/slow-henry ([0f9041b](https://github.com/bemble/slow-henry/commit/0f9041beb70564dc3d52dad52849197835d24ead))
* sync with upstream bbangert/slow-henry ([5ca6fdc](https://github.com/bemble/slow-henry/commit/5ca6fdc7f33418acead5e0a4cc20c2985f666603))

## [0.2.0](https://github.com/bemble/slow-henry/compare/v0.1.0...v0.2.0) (2026-10-23)


### Features

* publish a multi-arch Docker image with release-please versioning ([1d04f75](https://github.com/bemble/slow-henry/commit/1d04f75b9fcf4da6561744594384da08fe2c629f))
* publish a multi-arch Docker image with release-please versioning ([e479d1d](https://github.com/bemble/slow-henry/commit/e479d1dcd46d2292536e3c7075803625ba9d850b))


### Bug Fixes

* **ci:** inspect the published image by its metadata version ([546f6a2](https://github.com/bemble/slow-henry/commit/546f6a273ead7004bcca189e22aa5a832951896d))
* **ci:** inspect the published image by its metadata version ([6de0b7b](https://github.com/bemble/slow-henry/commit/6de0b7bfe8e62c33790cae32cca0b18eadd99384))
* clear Dialyzer warnings on OTP 29 ([0fd2511](https://github.com/bemble/slow-henry/commit/0fd25113664b24f320a70c87c9cc1391ea833193))
* **deps:** bump plug_crypto to 2.2.1 (EEF-CVE-2026-105963) ([5983149](https://github.com/bemble/slow-henry/commit/5983149b1dcf2a500f749b6bdbbc9d8e88932337))
