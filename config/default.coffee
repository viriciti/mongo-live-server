module.exports =
	port:  9999

	mongo:
		database:    "test_cs_live_data_server"
		initReplset: true
		throwHappy:  true
		options:
			poolSize: 50
			replicaSet: "rs0"

