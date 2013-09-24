var path = __dirname + '/' + (process.env.TEST_RESERVATION_COV ? 'lib-js-cov' : 'lib-js') + '/index';
module.exports = require(path);
