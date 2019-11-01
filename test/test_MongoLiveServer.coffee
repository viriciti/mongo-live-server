_                    = require "underscore"
assert               = require "assert"
async                = require "async"
config               = require "config"
moment               = require "moment"
qs                   = require "qs"
WebSocket            = require "ws"

{ initModels } = require "./lib"
MongoLiveServer = require "../src"


describe "Mongo Live Server Test", ->
	address  = "ws://localhost:#{config.port}"
	WAIT_FOR_WATCH  = 1000
	models          = null
	mongoLiveServer = null
	mongoConnector  = null

	process.on "unhandledRejection", (error) ->
		console.error "unhandledRejection", error

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
	,
		identity:      "sakif"
		chargestation: "identity"
	]

	aclClient =
		getChargestations: (userId, cb) ->
			acls = _.where aclGroups, identity: userId

			setTimeout ->
				cb null, acls
			, 50

	getAllowed = ({ ids, aclHeaders }, cb) ->
		ids = [].concat ids

		aclClient.getChargestations aclHeaders["user-id"], (error, acls) ->
			return console.error "Error getting allowed chargestations: #{error}" if error

			allChargestations = _.pluck acls, "chargestation"

			return cb null, allChargestations if ids.length is 0

			diff = _.difference ids, allChargestations

			if diff.length
				return cb new Error "User attempted to subscribe to not allowed ids! #{diff.join " "}"

			cb null, ids

	sendJson = (data) ->
		@send JSON.stringify data

	parseMessage = (message) ->
		try
			message = JSON.parse message
		catch error
			throw new Error "Error parsing message recieved over socket: #{error}. Message:", message

		message

	describe "WebSocket mongo connect interaction test", ->
		@timeout 12 * 1000

		before (done) ->
			async.series [
				(cb) ->
					mongoLiveServer = new MongoLiveServer
						mongo:            _.extend {}, config.mongo, useMongoose: true
						# Gauge:            Gauge
						getAllowed:       getAllowed
						port:             config.port
						watches: [
							path:             "chargestations"
							model:            "Chargestation"
							identityKey:      "identity"
							blacklistFields: ["forbiddenField"]
						]

					mongoLiveServer.start cb

				(cb) ->
					initModels mongoLiveServer.mongooseConnection

					{ models } = mongoLiveServer

					cb()

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
			mongoLiveServer.stop done


		it "should create a socket connection, keep track of watches", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			socket = new WebSocket "#{address}/chargestations/live", options

			socket
				.once "error", done
				.once "open", () ->
					setTimeout ->
						connectionId = (_.keys mongoLiveServer.changeStreams)[0]

						assert.ok not (_.isEmpty mongoLiveServer.changeStreams), "added a watch"
						assert.equal (_.keys mongoLiveServer.changeStreams).length, 1

						assert.ok mongoLiveServer.changeStreams[connectionId], "did not add watch"

						socket.close()

						done()
					, WAIT_FOR_WATCH
			return

		it "should reject connection for unknown route", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			socket = new WebSocket "#{address}/bogus/live", options

			socket
				.on "close", (statusCode) ->
					assert.equal statusCode, 4004, "Eh? this should be the code"
					done()
			return

		it "should reject connection when `getAllowed` calls back with error", (done) ->
			chargestation       = testDocs[2].identity
			identity            = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			query = qs.stringify
				ids:       [ chargestation ]

			socket = new WebSocket "#{address}/chargestations/live?#{query}", options

			socket
				.on "close", () ->
					done()
			return

		it "should cleanup watches upon disconnect", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			socket = new WebSocket "#{address}/chargestations/live", options

			socket
				.once "error", done
				.once "open", () ->
					setTimeout ->
						socket.close()
					, WAIT_FOR_WATCH / 4

					setTimeout ->
						sockets = mongoLiveServer.wsServer.clients.size

						streams = (_.keys mongoLiveServer.changeStreams).length

						assert.equal sockets, 0
						assert.equal streams, 0

						done()
					, WAIT_FOR_WATCH
			return

		it "should have 1 socket and 1 stream after multiple reconnects", (done) ->
			identity            = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			openAndCloseSocket = (cb) ->
				socket = new WebSocket "#{address}/chargestations/live", options

				socket
					.once "error", done
					.once "open", () ->
						setTimeout ->
							socket.close()
							cb()
						, 100

			functions = _.map [0...10], ->
				(cb) ->
					openAndCloseSocket cb

			async.parallel functions, (error) ->
				return done error if error

				socket = new WebSocket "#{address}/chargestations/live", options

				setTimeout ->
					sockets = mongoLiveServer.wsServer.clients.size

					streams = (_.keys mongoLiveServer.changeStreams).length

					assert.equal sockets, 1
					assert.equal streams, 1

					done()
				, 1000

		it "for all docs in querystring", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

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
					"user-id": identity

			query = qs.stringify extension: ["user-id"]

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

		it "send all extenstion fields", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			query = qs.stringify
				subscribe:     ["create", "update"]
				extension:     ["active", "identity", "alive"]
				fields:        ["alive"]

			path = "#{address}/chargestations/live?#{query}"

			socket = new WebSocket path, options

			socket.on "message", (message) ->
				message = parseMessage message

				assert.equal message.update.alive,  false
				assert.equal message.update.active, true
				assert.equal message.update.identity, "identity"
				socket.close()
				done()

			databaseFlow = ->
				(new models.Chargestation identity: "identity").save (error, doc) ->
					return done error if error

					data =
						active: true

					(_.extend doc, data).save (error, doc) ->
						return done error if error

			socket
				.once "error", done
				.once "open", () ->

					setTimeout ->

						databaseFlow()

					, WAIT_FOR_WATCH
			return

		# Actually should not even open the socket, reject it
		it "close socket for non existent model", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			query = qs.stringify extension: ["user-id"]

			path = "#{address}/fake_stations/live?#{query}"

			socket = new WebSocket path, options

			socket
				.once "error", done
				.once "open", () ->
				.once "close", () ->
					# done new Error "Opened socket for non existent error"
					done()

			return

		it "for specified operation type(s) (and also fields fields)", (done) ->
			identity = aclGroups[0].identity

			options =
				headers:
					"user-id": identity

			query = qs.stringify
				subscribe: ["insert"]
				fields:    ["identity", "active", "nested.field"]

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
					assert.ok message.insert.nested.field, "insert messages did not have nested.field!"
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
					, WAIT_FOR_WATCH

			databaseFlow = ->
				update = $set: lastHeartbeat: moment().toISOString()
				where  = identity: testDocs[1].identity

				cs = new models.Chargestation
					identity:      "hidden charge station"
					lastHeartbeat: moment().toISOString()
					active:        true
					nested:
						field:  "one!"

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

