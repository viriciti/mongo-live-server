# Mongo Live Server

## Description

Mongo Live Server serves live data from MongoDB over a websocket with just one simple configuration of less then 15 lines. Operations in MongoDB are served directly from a [replica set oplog](https://docs.mongodb.com/manual/core/replica-set-oplog/) over an websocket API in a read-only fashion using the new [MongoDB Change Streams](https://docs.mongodb.com/manual/changeStreams/). So, if you have a service that writes to a MongoDB database and you're in need of a service that reads those updates, Mongo Live Server is a simple and elegant solution! Instead of writing complete microservices using boilerplate code over and over again, use one module instead. Why reinvent the wheel? Also, using Mongo Live Server across multiple services provides API consistency; very convenient!

Mongo Live Server combines the following well-known modules:
- [MongoDB](https://www.npmjs.com/package/mongodb): The official MongoDB driver for Node.js.
- [WS](https://www.npmjs.com/package/ws): Simple, blazing fast, and thoroughly tested WebSocket server implementation.

At the same time, Mongo Live Server aims to provide full access to all functionalities of these dependencies.

Optionally, Mongo Live Server can also be used in combination with [Mongoose](https://www.npmjs.com/package/mongoose), a MongoDB object modeling tool, mainly for writing database models. With one single setting Mongo Live Server can start up with either MongoDB connections or Mongoose connections, respectively relying on MongoDB collections or Mongoose models. To do so, set `useMongoose` setting to true and run `npm i mongoose` in your project.

## Inspired by
We highly recommend using [Express Restify Mongoose](https://www.npmjs.com/package/express-restify-mongoose) for creating database services with RESTful API's in a similar fashion. Easy to understand. Quick and painless.

Moreover, Mongo Live Server is the Express Restify Mongoose for live data!

## How to install
```sh
npm i mongo-live-server
```

## How to use

Make sure to provide the `replicaSet` option. MongoDB Change Streams rely on the database to be a replicaset. Note that replicasets are allowed to have one single member.

### Configuration
```coffee
config =
	# WS server port (optional). Default: random
	port:                 7777

	mongo:
		# Database name (required).
		database:        "people-database"

		# Whether to throw errors on mongo connection problems (optional). Default: false
		throwHappy:       true

		# Use this to let the module init a replicaset automatically on startup
		initReplset: true

		# MongoDB (or Mongoose) connection options
		options:
			poolSize:     50   # (optional). Default: 5. Minimum: 5
			replicaSet:  "rs0" # (required).

		# Hosts array (required).
		# Needs at least one item.
		# Can supply multiple hosts for multiple membered replicasets.
		hosts: [
			host: "localhost" # MongoDB host name (required).
			port: 27017       # MongoDB port (required).
		]

		# Whether or not to use Mongoose (optional). Default: false
		useMongoose: false

	# Watch configuration. (required)
	# Which MongoDB collections / Mongoose models should updates be served from?
	# Needs at least one item.
	watches: [
		# path (required).
		# Serve data for this collection/model over a socket connection
		# Address is ws://[host][:port]/[path]/live
		path:             "pets"

		# collection/model (required).
		# Serve data for this MongoDB collection or Mongoose model.
		# either
		collection:       "pets"
		# or
		model:            "Pet"

		# identityKey (optional). Default: "identity"
		# The field that is used for ACL in the aggregation pipeline of the change stream.
		# see `getAllowed`
		identityKey:      "identity"

		# Non-readable fields. (optional)
		blacklistFields: ["bankAcct"]
	]

	# Header name or query parameter for sending along user id (optional).
	# Default: "user-id"
	userIdentityKey: "user-id"

	# Asynchronous function for filtering requested ids (optional)
	# `ids` array can be a unique field like "identity" or shared field like "role".
	# This depends on `identityKey`
	# Example:
	getAllowed: ({ ids, userIdentity }, cb) ->

		# Perform a database call -> allowedIds

		# expensive filter:
		filteredIds = ids.filter (doc) ->
			allowedIds.includes userIdentity

		cb null, filteredIds
```

### Start and stop

For convenience sake and testing purposes, Mongo Live Server has start and stop functions. Both can be called synchronously ánd asynchronously, with or without a callback that is.

Moreover, if the `initReplset` setting is enabled, starting up Mongo Live Server will automatically initialise a replica set for the database on the provided host(s) and port(s). Obviously, this is not recommended in production.

```coffee
mongoLiveServer.start() # synchronous

mongoLiveServer.start (error) =>
	return cb error if error

	console.log "Mongo Live Server has successfully started!"

```

```coffee
mongoLiveServer.stop() # synchronous

mongoLiveServer.stop (error) =>
	return cb error if error

	console.log "Mongo Live Server has successfully stopped!"

```

### Convenience variables:

Use the Mongo Live Server to access the database. The variable `mongoLiveServer.db` is a reference to the currert connected database, specified in `config.mongo.database`. The variable `mongoLiveServer.db` can be used for example to open collections and write documents with native MongoDB functions, like:

```coffee
mongoLiveServer.db.collection("mycollection").insert
```

The connected native MongoDB Client can be found here" `mongoLiveServer.mongoClient`.

When using Mongoose and thus `useMongoose` is true, `mongoLiveServer.mongooseConnection` is the connection created with `mongoose.createConnection`. Use it to instantiate Mongoose models in the ordinary way, for example like this:

```coffee
schema = new Schema({ name: String })

connection = mongoLiveServer.mongooseConnection

connection.model("MyCollection", schema)

```

Once that is done, use `mongoLiveServer.models` to access the instantiated models, for example like:

```coffee
mongoLiveServer.models.MyCollection
```


### Connecting

To recieve all data for a collection/model, connect to the configured `path` postfixed with "/live". The live postfix is relevant to discriminate between routes used for live-data endpoints and routes used for e.g. RESTful endpoints. This way an application can have uniform paths.

```coffee
new WebSocket "ws://localhost:7777/pets/live", "user-id": "tes-user-123"
```

JSON messages received over the socket will, after parsing, be namespaced based on operation type. This means that if the operation type was `update`, then the object recieved will have a `update` key for which the value is the relevant document data:

```json
{
	"update": {
		"_id": "5751636e5539480100df6c43",
		"identity": "Kofi Annan",
		"job": "diplomat"
	}
}
```

Messages for the `insert` operation result in full documents. Messages for the `update` operation only contain the changed fields. Messags for the `delete` operation only contain the `_id` field.

### Querying

To request specific data, use a query string. To stringify it use the [qs](https://www.npmjs.com/package/qs) module. The [query-string](https://www.npmjs.com/package/query-string) module is currently not supported. If demanded, please create an issue. All query parameters are optional.

```coffee
qs = require "qs"

qs.stringify
	# Subscribe to specific operation types
	# Let the server know what MongoDB operation types, e.g. "insert" and/or "update" and/or "delete"
	subscribe:     ["update"]

	# Let the server know what fields the send documents should have.
	fields:        ["last name", "first name", "city", "email", "role", "bankAcct"]

	# Only in case of an subscription to "update" operations.
	# Messages for update operations only contain the updated fields.
	# Therefore, let the server know what fields should in all cases be added to the message.
	# This is needed for example for finding the relevant document in the client.
	extension:     ["identity"]

	# Let the server know what ids (relates to `identityKey`) should be watched
	ids:           []
```

### Server Example

```coffee
_                              = require "underscore"
async                          = require "async"
MongoLiveServer                = require "mongo-live-server"
manyPeople                     = require "random-people"


getAllowed = ({ ids, userIdentity }, cb) ->
	if userIdentity is "Kofi Annan"
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

Server = class Server
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

			console.log "Added #{people[0]["first name"]}
			 & #{people[1]["first name"]}
			 & #{people[2]["first name"]}"

	stop: (cb) =>
		clearInterval @interval
		mongoLiveServer.stop cb


server = new Server

server.start (error) ->
	throw error if error

	_.each [
		"SIGUSR2"
		"SIGTERM"
		"SIGINT"
	], (signal) ->
		process.on signal, _.once ->
			console.info "Got signal `#{signal}`. Closing down..."

			server.stop (error) ->
				throw error if error
				process.exit 0

process.on "unhandledRejection", (error) ->
	console.error "unhandledRejection", error
```

#### Client Example

```coffee
qs                   = require "qs"
WebSocket            = require "ws"

handleMessage = (message) ->
	try
		message = JSON.parse message
	catch error
		throw new Error "Parse error: #{error}. Message:", message

	console.log message

options =
	headers:
		"user-id": "joeri" # Change this name to test `getAllowed` ACl functionality

query = qs.stringify
	subscribe: ["insert"]
	fields:    ["last name", "first name", "city", "email", "role", "bankAcct"]

new WebSocket "ws://localhost:7777/persons/live?#{query}", options
	.on "message", handleMessage

```

## Contribute

Create an issue or a pull request.

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

# Contact the author

Contact Pim per email at heijden.pvd[at]gmail.com
