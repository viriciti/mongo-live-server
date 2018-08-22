# Mongo Live Server

## Description


## How to install
```sh
npm i mongo-live-server
```

With the `--save` flag for older version of NPM:
```sh
npm i --save mongo-live-server
```

When using yarn:

```sh
yarn add mongo-live-server
```

## How to use

### Convenience variables:

if @mongo.useMongoose
	@mongooseConnection = @mongoConnector.mongooseConnection
	@models             = @mongooseConnection.models
else
	@mongoClient = @mongoConnector.mongoClient
	@db          = @mongoConnector.db


## How to contribute

### Release

- Run `npm run release-test` to make sure that everything is ready and correct for publication on NPM.
- If the previous step succeeded, release a new master version with a raised version tag following the git flow standard.
- Run `npm run release` to finally publish the module on NPM.

## How to test

Run all the tests once with coverage:

```sh
npm test
```

Run all the tests without coverage and with a watch:

```sh
npm tests
```
