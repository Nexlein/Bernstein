var express = require('express'),
  pg = require('pg'),
  path = require('path'),
  app = express(),
  server = require('http').Server(app),
  io = require('socket.io')(server);

var db_config = {
  host: process.env['POSTGRES_HOST'],
  port: process.env['POSTGRES_PORT'],
  database: process.env['POSTGRES_DB'],
  user: process.env['POSTGRES_USER'],
  password: process.env['POSTGRES_PASSWORD'],
  // Give up after 5 s instead of waiting forever: a connection to a node that died would
  // otherwise hang until TCP gives up (minutes), and the scores would stay frozen that long.
  connectionTimeoutMillis: 5000,
  query_timeout: 5000,
};

io.sockets.on('connection', function (socket) {
  socket.emit('message', { text: 'Welcome!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// A pool opens a new connection when one breaks: a PostgreSQL restart or move no longer
// stops Result. The page keeps loading, and the scores resume once the database is back.
var pool = new pg.Pool(db_config);
// A broken idle connection is reported here; without a handler, it would crash the process.
pool.on('error', function (err) {
  console.error('Db connection error: ' + err);
});

// Ready once the database answered since the start: a wrong password or host never becomes
// ready (the rollout stops, the old pods keep serving), but a later outage keeps the pod in the
// Service instead of leaving it without endpoints.
var dbAnsweredOnce = false;

function getVotes() {
  pool
    .query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [])
    .then((result) => {
      if (!dbAnsweredOnce) console.log('Connected to db');
      dbAnsweredOnce = true;
      var votes = collectVotesFromResult(result);
      io.sockets.emit('scores', JSON.stringify(votes));
    })
    .catch((err) => {
      console.error('Waiting for db: ' + err.message);
    })
    .finally(() => {
      setTimeout(getVotes, 1000);
    });
}
getVotes();

function collectVotesFromResult(result) {
  var votes = { a: 0, b: 0, c: 0, d: 0 };

  result.rows.forEach(function (row) {
    votes[row.vote] = parseInt(row.count);
  });

  return votes;
}

app.use(function (req, res, next) {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');
  res.header('Access-Control-Allow-Methods', 'PUT, GET, POST, DELETE, OPTIONS');
  next();
});

app.use(express.static(__dirname + '/views'));

app.get('/', function (req, res) {
  res.sendFile(path.resolve(__dirname + '/views/index.html'));
});

app.get('/healthz', function (req, res) {
  res.sendStatus(200);
});

app.get('/readyz', function (req, res) {
  res.sendStatus(dbAnsweredOnce ? 200 : 503);
});

server.listen(80, function () {
  var port = server.address().port;
  console.log('App running on port ' + port);
});

// Rolling updates send SIGTERM: stop accepting, drain in-flight requests, then exit.
process.on('SIGTERM', function () {
  server.close(function () {
    process.exit(0);
  });
  io.close();
  setTimeout(function () {
    process.exit(0);
  }, 10000).unref();
});
