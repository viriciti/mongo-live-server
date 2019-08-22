_                    = require "underscore"
async                = require "async"
debug                = (require "debug") "mongo-live-server"
pingPongDebug        = (require "debug") "ping-pong"
dot                  = require "dot-object"
http                 = require "http"
uuid                 = require "uuid"
qs                   = require "qs"
WebSocket            = require "ws"
MongoConnector       = require "mongo-changestream-connector"


{ defaultLogger }    = require "./lib"


class MongoLiveServer
	constructor: (args) ->
		{
			@port
			@httpServer
			log
			@mongo
			@watches
			Gauge
			metricLabel
			@getAllowed
			@pingPong
			@aclHeaders = [
				"user-id"
				"company-id"
			]
		} = args

		@getAllowed or= ({ ids, aclHeaders }, cb) ->
			debug "Received ACL Headers but discarding them. ACl headers:", aclHeaders
			cb null, ids

		defaultLabel = "mongo-live-server"
		@log         = log or defaultLogger defaultLabel
		metricLabel  = metricLabel or (@log.label ? defaultLabel).replace /-/g, "_"

		@log.warn "Mongo Live Server running without `getAllowed` function!" unless @getAllowed

		debug "TN-log & prometheus metric label is: #{metricLabel}"

		# Config validation of @mongo happens in mongo-changestream-connector
		unless @mongo
			throw new Error "Mongo config must be provided to create Mongo Live Server"
		unless @port or @httpServer
			throw new Error "httpServer or port must be provided to create Mongo Live Server"

		@unControlledHTTP      = Boolean @httpServer
		@httpServer          or= http.createServer()
		@changeStreams         = {}
		@defaultOperationTypes = ["update", "insert"]

		# two more operation types
		# @defaultOperationTypes = ["update", "insert", "delete", "replace", "invalidate"]

		#######################################
		# Why two gauges?
		# Value of gauge streams and of gauge sockets should be identical!
		#######################################

		@gaugeStreams = if Gauge then new Gauge
			name:       "#{metricLabel}_change_stream_count"
			help:       "Counts the change streams of the of the Mongo Live Server"
			labelNames: [ "live_data_server_streams" ]

		@gaugeSockets = if Gauge then new Gauge
			name:       "#{metricLabel}_active_socket_count"
			help:       "Counts the connected sockets"
			labelNames: [ "identity" ]

		throw new Error "Should provide at least one watch configuration." unless @watches.length >= 1

		_.each @watches, (route) =>
			{ path, model, collection, blacklistFields } = route

			throw new Error "Watch configuration should have a path." unless path

			livePath = "/#{path}/live"

			if @mongo.useMongoose and collection
				throw new Error "Each watch config object should have the `model` property (and not `collection`)"
			if not @mongo.useMongoose and model
				throw new Error "Each watch config object should have the `collection` property (and not `model`)"

			debug "Setting up web socket server for path: #{livePath}.
			 #{if blacklistFields then "Blacklist: " + blacklistFields.join " " else ""}"

		@mongoConnector = new MongoConnector _.extend {}, @mongo, log: @log
		@wsServer       = new WebSocket.Server server: @httpServer

		@wsServer.on "connection", @_handleConnection

		if @pingPong
			@log.info "Mongo Live Server Running with ping pong"

			@pingPongInterval = setInterval =>
				# Can't use underscore _.forEach
				@wsServer.clients.forEach (socket) =>
					if not socket.isAlive
						@log.error "Closing not alive socket. Connection id: #{socket.streamId}"
						return socket.terminate()

					socket.isAlive = false

					socket.ping ->
						pingPongDebug "ping - Connection id: #{socket.streamId}"
			, @pingPong

	_updateGaugeStreams: =>
		mnt = (_.keys @changeStreams).length

		return unless @gaugeStreams

		debug "Updating amount of streams gauge: #{mnt}"

		@gaugeStreams.set mnt

	_updateGaugeSockets: =>
		mnt = @wsServer.clients.size

		return unless @gaugeSockets

		debug "Updating amount of sockets gauge: #{mnt}"

		@gaugeSockets.set mnt

	_setupStream: (payload, cb) =>
		{
			identityKey = "identity"
			ids
			model
			collection
			onChange
			onClose
			onError
			pipeline
			socket
			streamId
			aclHeaders
		} = payload

		@getAllowed { ids, aclHeaders }, (error, allowed) =>
			if error
				mssg = "Error getting allowed `#{model or collection}` documents: #{error}"
				return cb new Error mssg

			# Because `getAllowed` is asynchronous we need to check connection
			unless socket.readyState is WebSocket.OPEN
				return cb new Error "Socket disconnected while getting allowed ids"

			pipeline[0].$match.$and or= []

			if Array.isArray allowed
				pipeline[0].$match.$and.push "fullDocument.#{identityKey}": $in: allowed

			@changeStreams[streamId] = @mongoConnector.changeStream {
				model
				collection
				streamId
				onError
				onClose
				onChange
				pipeline
				options:
					fullDocument: "updateLookup" # make this optionable in query?
			}

			@_updateGaugeStreams()

			cb()

	_handleConnection: (socket, req) =>
		url = req.url.split("/live").shift().slice(1)

		# This step shoule actually take place in the authorization process of the WS server, right before upgrade
		route = _.find @watches, path: url

		return socket.close 4004, "Path `#{url}` not found" unless route

		debug "incoming connection with route `#{url}`"

		{ identityKey, model, collection, blacklistFields } = route

		streamId                 = uuid.v4()
		socket.streamId          = streamId

		aclHeaders               = _.pick req.headers, @aclHeaders
		ip                       = req.connection.remoteAddress
		splitUrl                 = req.url.split "?"
		query                    = qs.parse splitUrl[1]
		subscribe                = query.subscribe or @defaultOperationTypes
		{
			fields          = []
			extension       = []
			ids             = []
		} = query

		extension       = [ extension ]       if typeof extension is "string"
		subscribe       = [ subscribe ]       if typeof subscribe is "string"
		fields          = [ fields ]          if typeof fields    is "string"
		ids             = [ ids ]             if typeof ids       is "string"

		pipeline = [
			$match:
				$and: []
		]

		operationCondition = _.map subscribe, (operationType) ->
			{ operationType }

		pipeline[0].$match.$and.push $or: operationCondition

		##########################
		# TODO if fields and/or excludeFields, apply it in two ways
		##########################

		# 	trigger only on changes on these fields
		# 	$or: _.map ["lastHeartBeart", "alive"], (field) ->
		# 		"updateDescription.updatedFields.#{field}": $exists: true

		# 	for operationType insert give us only these fields
		# 	$project:
		# 		identity:   1
		# 		alive:      1
		# 		connectors: 1

		onChange = (change) =>
			unless socket.readyState is WebSocket.OPEN
				return @log.error "Socket not open. Connection id: #{streamId}"

			{ operationType } = change

			switch operationType
				when "insert"
					if fields.length
						data = {}

						_.forEach fields, (fieldName) ->
							val = dot.pick fieldName, change.fullDocument
							dot.str fieldName, val, data
					else
						data = change.fullDocument

				when "update"
					update = change.updateDescription.updatedFields

					extra = {}

					_.forEach extension, (fieldName) ->
						val = dot.pick fieldName, change.fullDocument
						dot.str fieldName, val, extra

					data  = _.extend {}, update, extra

			unless data
				throw new Error "Could establish message for operation type: #{operationType}"

			data = _.omit data, blacklistFields

			socket.send (JSON.stringify "#{operationType}": data), (error) =>
				@log.error error if error

		##############
		# change stream close <-> socket terminate
		#########

		onClose = =>
			unless @changeStreams[streamId]
				return debug "Change stream already cleaned up. Connection id: #{streamId}"

			delete @changeStreams[streamId]
			@_updateGaugeStreams()

			socket.terminate()
			# socket.close()

		onError = (error) =>
			@log.error "Change stream error: #{error}"

			unless @changeStreams[streamId]
				return debug "Change stream already cleaned up. Connection id: #{streamId}"

			@changeStreams[streamId].close()

		handleSocketDisconnect = =>
			@log.info "Client disconnected. Connection id: #{streamId}"

			@_updateGaugeSockets()

			unless @changeStreams[streamId]
				return debug "Change stream already cleaned up. Connection id: #{streamId}"

			@changeStreams[streamId].close()

		handleSocketError = (error) =>
			socket.terminate()
			# socket.close()
			@log.error "Websocket error: #{error.message}"

		@_setupStream {
			identityKey
			ids
			model
			collection
			onChange
			onClose
			onError
			pipeline
			socket
			streamId
			aclHeaders
		}, (error) =>
			if error
				debug error.message
				return socket.close 4000

			socket
				.on "close", handleSocketDisconnect
				.on "error", handleSocketError

			if @pingPong
				pong = ->
					pingPongDebug "pong - Connection id: #{socket.streamId}"
					@isAlive = true

				socket.isAlive = true
				socket.on 'pong', pong

			@log.info "Client connected. Connection id: #{streamId}", { extension, fields, ids, ip, subscribe, url, aclHeaders }

			@_updateGaugeSockets()

	start: (cb) =>
		debug "starting"

		async.series [
			(cb) =>
				return cb() unless @mongo.initReplset

				@mongoConnector.initReplset cb

			(cb) =>
				@mongoConnector.start (error) =>
					return cb error if error

					if @mongo.useMongoose
						@mongooseConnection = @mongoConnector.mongooseConnection
						@models             = @mongooseConnection.models
					else
						@mongoClient = @mongoConnector.mongoClient
						@db          = @mongoConnector.db

					cb()

			(cb) =>
				return cb() if @unControlledHTTP
				return cb() if @httpServer.listening

				@httpServer.listen port: @port, (error) =>
					return cb error if error

					@log.info "WebSocket server listening on #{@httpServer.address().port}"

					cb()

		], (error) ->
			return cb? error if error

			debug "started"

			cb?()

	stop: (cb) =>
		debug "stopping"

		clearInterval @pingPongInterval

		# Sockets do NOT close when http server.close is called
		# Can't use underscore _.forEach
		@wsServer.clients.forEach (socket) ->
			socket.terminate()
			# socket.close()

		async.series [
			(cb) =>
				@mongoConnector.stop cb

			(cb) =>
				return cb() if @unControlledHTTP
				return cb() unless @httpServer.listening

				@httpServer.close (error) =>
					return cb error if error

					@log.info "WebSocket server stopped listening"

					cb()
		], (error) ->
			return cb? error if error

			debug "stopped"

			cb?()

module.exports = MongoLiveServer
