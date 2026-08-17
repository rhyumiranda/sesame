# Changelog

## [0.5.1](https://github.com/rhyumiranda/sesame/compare/v0.5.0...v0.5.1) (2026-08-17)


### Bug Fixes

* **app:** surface Touch ID approval for background socket get requests ([#25](https://github.com/rhyumiranda/sesame/issues/25)) ([510f645](https://github.com/rhyumiranda/sesame/commit/510f6456b921d427a3e4fc777d2ed67b6759a4ac))

## [0.5.0](https://github.com/rhyumiranda/sesame/compare/v0.4.0...v0.5.0) (2026-08-16)


### Features

* **cli:** add branded banner, sesame setup PATH wiring, and clearer init next-steps ([3826af3](https://github.com/rhyumiranda/sesame/commit/3826af3f7de65b2c89bc47d89df818bbacff8e7b))

## [0.4.0](https://github.com/rhyumiranda/sesame/compare/v0.3.0...v0.4.0) (2026-08-16)


### Features

* **app:** run the agent socket from the menu-bar app ([2dcc7c9](https://github.com/rhyumiranda/sesame/commit/2dcc7c95c7de1cd5f8a4e5eab42113f255d08c30))
* **app:** SesameApp menu-bar target + popover UI ([a9ad425](https://github.com/rhyumiranda/sesame/commit/a9ad425f825a25ce9dc50ced2f3deadf1dfb5d45))
* **app:** SMAppService auto-start toggle ([ab7ca39](https://github.com/rhyumiranda/sesame/commit/ab7ca39ea648cf025fff2b6301bfa642dc286c27))
* **app:** windowed UI — Dock icon + main window matching the mock-up ([ad1330b](https://github.com/rhyumiranda/sesame/commit/ad1330bf8300dc18f11c0097d39b1af71a4ff5dc))
* **cli:** add sesame exec, init, and on-demand secret shims ([a04eba1](https://github.com/rhyumiranda/sesame/commit/a04eba1dddf956371c7d15e2feac3d1942daff38))
* **cli:** CLI-as-client routing + migrate/export/import recovery ([389acd8](https://github.com/rhyumiranda/sesame/commit/389acd829eb4349fb438079a69f763adf35b823c))
* **core:** add .sesame manifest parser/loader and PATH-dir shim rendering ([6537115](https://github.com/rhyumiranda/sesame/commit/6537115122366c511d49093784567882d752b469))
* **core:** agent socket protocol + server + client ([cb7f7ca](https://github.com/rhyumiranda/sesame/commit/cb7f7ca22e56d052738a411be3fa7c2aa6b9edf0))
* **core:** StorageBackend protocol + Secure-Enclave store + Config ([7d04031](https://github.com/rhyumiranda/sesame/commit/7d04031cdfa93b051431852865eeaf249f886697))
* **mvp:** JSONL access log + execve env-injection runner ([b2a834a](https://github.com/rhyumiranda/sesame/commit/b2a834a36fba14df6885944f4c60cccf208a4fa1))
* **mvp:** login-Keychain store + OSStatus error map ([ad6041b](https://github.com/rhyumiranda/sesame/commit/ad6041bd73b51cc3ad6c9008ff145833fa494d3c))
* **mvp:** six AXI-shaped CLI commands + no-args dashboard ([ec81756](https://github.com/rhyumiranda/sesame/commit/ec817563037e3a1481539fe695453784306b54e0))
* **mvp:** Touch ID gate behind an Authenticator protocol + rate limiter ([510a49c](https://github.com/rhyumiranda/sesame/commit/510a49ceb02a0fa1abf1864b432aecaf4b4db7b6))


### Bug Fixes

* **app:** use AppKit NSStatusItem so the menu-bar icon reliably shows ([3fd1eae](https://github.com/rhyumiranda/sesame/commit/3fd1eae23c5ccfce77c2059bb2161b1381a22f75))
