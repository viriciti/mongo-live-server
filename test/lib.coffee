module.exports =
	initModels: (connection) ->
		{ models } = connection
		{ Schema } = connection.base

		schema = new Schema
			active:
				type:     Boolean
				default:  false

			identity:       type: String, unique: true

			lastHeartbeat:  type: Date

			alive:
				type:    Boolean
				default: false

		,
			timestamps: true

		connection.model "Chargestation", schema
