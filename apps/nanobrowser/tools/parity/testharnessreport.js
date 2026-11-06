// In place of WPT's `resources/testharnessreport.js`, as wptrunner replaces it: tells
// `wpt_run.py` how a test ended, then asks it for the next. Counts travel rather
// than every subtest's name: some tests have thousands.
(function () {
  if (typeof window === 'undefined' || window.top !== window || window.opener) return;
  setup({ output: false });
  var collector = 'http://web-platform.test:9099';
  var post = window.fetch && window.fetch.bind(window);
  var replace = window.location.replace.bind(window.location);
  var url = window.location.pathname + window.location.search;
  add_completion_callback(function (tests, status) {
    var pass = 0;
    var fails = [];
    for (var i = 0; i < tests.length; i++) {
      if (tests[i].status === 0) pass++;
      else if (fails.length < 20) {
        fails.push([tests[i].status, String(tests[i].name).slice(0, 160), String(tests[i].message || '').slice(0, 200)]);
      }
    }
    var body = JSON.stringify({
      url: url,
      harness: status.status,
      message: String(status.message || '').slice(0, 300),
      pass: pass,
      total: tests.length,
      fails: fails,
    });
    var next = function () { replace(collector + '/next?after=' + encodeURIComponent(url)); };
    if (!post) return next();
    post(collector + '/report', { method: 'POST', mode: 'no-cors', body: body }).then(next, next);
  });
})();
