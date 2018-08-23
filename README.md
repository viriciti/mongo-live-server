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
```
async                          = require "async"
MongoLiveServer                = require "mongo-live-server"
manyPeople                     = require "random-people"


getAllowed = ({ ids, userIdentity }, cb) ->
	if userIdentity is "tamme thijs"
		return cb null, [ "admin" ]

	cb null, [ "user", "designer" ]


mongoLiveServer = new MongoLiveServer
	port:       7777
	mongo:
		database:        "mongo-live-server-example"
		throwHappy:       true
		options:
			poolSize:     50
			replicaSet:  "rs0"
		hosts: [
			host: "localhost"
			port: 27017
		]
	watches: [
		path:             "persons"
		collection:       "persons"
		identityKey:      "role"
		blacklistFields: ["bankAcct"]
	]
	getAllowed:           getAllowed

module.exports = class App
	constructor: ->

	start: (cb) ->
		mongoLiveServer.start (error) =>
			return cb error if error

			cb()

			@collection = mongoLiveServer.mongoConnector.db.collection "persons"

			@createPeople()

	createPeople: =>
		@interval = setInterval @createPerson, 3000

	createPerson: =>
		people = manyPeople 3

		people[0].role = "admin"
		people[1].role = "user"
		people[2].role = "designer"

		@collection.insert people, (error) ->
			console.error error if error

			console.log "Added #{people[0]["first name"]} & #{people[1]["first name"]} & #{people[2]["first name"]}"

	stop: (cb) =>
		clearInterval @interval
		mongoLiveServer.stop cb
```


### Convenience variables:

if `useMongoose` is true:

```
	mongoLiveServer.mongooseConnection
	mongoLiveServer.models
```

if not:
```
	mongoLiveServer.mongoClient
	mongoLiveServer.db
```

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
