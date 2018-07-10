module.exports =
	host: "localhost"
	port:  9999

	db:
		database: "test_cs_live_data_server"
		hosts: [
			host: "mongo"
			port: 27017
		]
		throwHappy: false
		poolSize: 50
		options:
			replicaSet: "rs0"
