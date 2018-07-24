_                    = require "underscore"
assert               = require "assert"
async                = require "async"
config               = require "config"
moment               = require "moment"
MongoConnector       = require "@tn-group/mongo-connector"
qs                   = require "qs"
WebSocket            = require "ws"

{ initModels } = require "./lib"
LiveDataServer    = require "../src"

WAIT_FOR_WATCH = 200
models         = null
liveDataServer = null
mongoConnector = null


describe "LiveDataServer Test", ->
	address  = "ws://localhost:#{config.port}"

	process.on "unhandledRejection", (error) ->
		console.error "unhandledRejection", error

	mongoConnector = new MongoConnector
		database: config.db.database
		hosts:    config.db.hosts
		options:  config.db.options
		poolSize: config.db.poolSize

	aclGroups = [
			identity:      "sakif"
			chargestation: "sakifs first station"
		,
			identity:      "sakif"
			chargestation: "sakifs second station"
		,
			identity:      "sakif"
			chargestation: "read this"
		,
			identity:      "sakif"
			chargestation: "hidden charge station"
		,
			identity:      "pim"
			chargestation: "pims first station"
	]

	aclClient =
		getChargestations: (userId, cb) ->
			acls = _.where aclGroups, identity: userId
			setTimeout ->
				cb null, acls
			, 100

	testDocs = [
			identity:      "sakifs first station"
			lastHeartbeat: moment().toISOString()
			active:        true
		,
			identity:      "sakifs second station"
			lastHeartbeat: moment().toISOString()
			active:        true
		,
			identity:      "pims first station"
			lastHeartbeat: moment().toISOString()
			active:        true
	]

	sendJson = (data) ->
		@send JSON.stringify data

	parseMessage = (message) ->
		try
			message = JSON.parse message
		catch error
			throw new Error "Error parsing message recieved over socket: #{error}. Message:", message

		message

	describe "WebSocket mongo connect interaction test", ->
		before (done) ->
			@timeout 300000

			async.series [
				(cb) ->
					mongoConnector.initReplset cb

				(cb) ->
					mongoConnector.start (error) ->
						return cb error if error

						initModels mongoConnector.connection

						{ models } = mongoConnector.connection

						cb()

				(cb) ->
					liveDataServer = new LiveDataServer
						mongoConnector:   mongoConnector
						aclClient:        aclClient
						options:
							port:         config.port
							host:         config.host
						watches: [
							path:             "chargestations"
							model:            "Chargestation"
							identityKey:      "identity"
							blacklistFields: ["forbiddenField"]
						]

					liveDataServer.start cb

				(cb) ->
					models.Chargestation
						.remove({})
						.exec cb

				(cb) ->
					docs = []
					docs.push new models.Chargestation testDocs[0]
					docs.push new models.Chargestation testDocs[1]

					async.each docs, (doc, cb) ->
						doc.save cb
					, cb

			], done

		after (done) ->
			async.series [
				(cb) ->
					liveDataServer.stop cb

				(cb) ->
					mongoConnector.stop cb
			], done

		it "should create a socket connection, keep track of watches", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			socket = new WebSocket "#{address}/chargestations/live", options

			socket
				.once "error", done
				.once "open", () ->
					setTimeout ->
						connectionId = (_.keys liveDataServer.changeStreams)[0]

						assert.ok not (_.isEmpty liveDataServer.changeStreams), "added a watch"
						assert.equal (_.keys liveDataServer.changeStreams).length, 1

						assert.ok liveDataServer.changeStreams[connectionId], "did not add watch"

						socket.close()

						done()
					, WAIT_FOR_WATCH
			return

		it "should reject unknown route", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			socket = new WebSocket "#{address}/bogus/live", options

			socket
				.once "close", (statusCode) ->
					assert.equal statusCode, 4004, "Eh? this should be the code"
					done()
			return

		it "should cleanup watches upon disconnect", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			socket = new WebSocket "#{address}/chargestations/live", options

			socket
				.once "error", done
				.once "open", () ->
					socket.close()

					setTimeout ->
						sockets = liveDataServer.wsServer.clients.size

						streams = (_.keys liveDataServer.changeStreams).length

						assert.equal sockets, 0
						assert.equal streams, 0

						done()
					, WAIT_FOR_WATCH
			return

		it "should have 1 socket and 1 stream after multiple reconnects", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			openAndCloseSocket = (close) ->
				socket = new WebSocket "#{address}/chargestations/live", options

				socket
					.once "error", done
					.once "open", () ->
						socket.close() if close

			_.each [0...10], ->
				openAndCloseSocket true

			openAndCloseSocket false

			setTimeout ->
				sockets = liveDataServer.wsServer.clients.size

				streams = (_.keys liveDataServer.changeStreams).length

				assert.equal sockets, 1
				assert.equal streams, 1

				done()
			, 1000

		it "for all docs in querystring", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			query = qs.stringify
				ids:       [testDocs[0].identity]
				extension: ["identity"]

			path = "#{address}/chargestations/live?#{query}"

			socket = new WebSocket path, options

			socket.on "message", (message) ->
				message = parseMessage message

				if message.update.identity isnt testDocs[0].identity
					clearTimeout timeoutId
					done new Error "Received update for wrong chargestation"

				timeoutId = setTimeout ->
					socket.close()
					done()
				, 500


			databaseFlow = ->
				update  = $set: lastHeartbeat: moment().toISOString()
				where1  = identity: testDocs[1].identity
				where0  = identity: testDocs[0].identity

				models.Chargestation
					.findOneAndUpdate where1, update
					.exec (error) ->
						return done error if error

						models.Chargestation
							.findOneAndUpdate where0, update
							.exec (error) ->
								return done error if error

			socket
				.once "error", done
				.once "open", () ->

					setTimeout ->

						databaseFlow()

					, WAIT_FOR_WATCH
			return

		it "not response with forbidden fields", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			query = qs.stringify extension: ["identity"]

			path = "#{address}/chargestations/live?#{query}"

			socket = new WebSocket path, options

			socket.on "message", (message) ->
				message = parseMessage message

				assert.ok not message.insert.forbiddenField, "did send forbidden field!"
				socket.close()
				done()

			databaseFlow = ->
				data =
					identity:       "read this"
					forbiddenField: "don't read this"

				(new models.Chargestation data).save (error) ->
					return done error if error

			socket
				.once "error", done
				.once "open", () ->

					setTimeout ->

						databaseFlow()

					, WAIT_FOR_WATCH
			return

		it "for specified operation type(s) (and also fields fields)", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"identity": identity

			query = qs.stringify
				subscribe: ["insert"]
				fields:    ["identity", "active"]

			path = "#{address}/chargestations/live?#{query}"

			socket = new WebSocket path, options

			socket.on "message", (message) ->
				message = parseMessage message

				if message.update
					clearTimeout timeoutId
					done new Error "Should NOT receive update message!"

				if message.insert
					inserted = true
					assert.ok message.insert.identity, "insert messages did NOT have identity!"
					assert.equal typeof message.insert.active, "boolean", "insert messages did NOT have active!"
					assert.ok not message.insert.lastHeartbeat, "insert messages did have lastHeartbeat!"

				# Delete changes are based on _id only, not on a field like `identity` or `chargestation`.
				# Considering the currenct acl of the CS, delete changes can never be queried for.
				# They are thus irrelevant.

				# if message.delete
				# 	deleted  = true
				# 	assert.ok message.delete._id, "delete messages did not have _id"

				# if inserted and deleted
				if inserted
					timeoutId = setTimeout ->
						socket.close()
						done()
					, 500

			databaseFlow = ->
				update = $set: lastHeartbeat: moment().toISOString()
				where  = identity: testDocs[1].identity

				cs = new models.Chargestation
					identity:      "hidden charge station"
					lastHeartbeat: moment().toISOString()
					active:        true

				cs.save (error) ->
					return done error if error

					cs.active = false

					cs.save (error) ->
						return done error if error

						cs.remove (error) ->
							return done error if error

			socket
				.once "error", done
				.once "open", () ->
					setTimeout ->

						databaseFlow()

					, WAIT_FOR_WATCH
			return

