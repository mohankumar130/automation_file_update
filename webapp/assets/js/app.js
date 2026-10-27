/* Sports Mech — client-side app (v3, colorful UI) */
(function () {
  "use strict";
  var KEY = "sportsmech.players";
  var form = document.getElementById("reg-form");
  var list = document.getElementById("player-list");
  var count = document.getElementById("count");

  function load() { try { return JSON.parse(localStorage.getItem(KEY)) || []; } catch (e) { return []; } }
  function save(p) { localStorage.setItem(KEY, JSON.stringify(p)); }

  function render() {
    var players = load();
    list.innerHTML = "";
    players.forEach(function (p, i) {
      var li = document.createElement("li");
      var left = document.createElement("div");
      left.innerHTML = '<strong>' + esc(p.name) + '</strong>' +
        '<div class="meta">' + esc(p.role) +
        (p.country ? ' · ' + esc(p.country) : '') + '</div>';
      var right = document.createElement("div");
      right.style.display = "flex";
      right.style.alignItems = "center";
      right.style.gap = "10px";
      var chip = document.createElement("span");
      chip.className = "chip";
      chip.textContent = "₹" + p.price + " Cr";
      var del = document.createElement("button");
      del.type = "button";
      del.textContent = "Remove";
      del.addEventListener("click", function () {
        var cur = load(); cur.splice(i, 1); save(cur); render();
      });
      right.appendChild(chip); right.appendChild(del);
      li.appendChild(left); li.appendChild(right);
      list.appendChild(li);
    });
    if (count) count.textContent = String(players.length);
  }

  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  if (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var f = new FormData(form);
      var name = (f.get("name") || "").trim();
      var role = (f.get("role") || "").trim();
      var price = (f.get("price") || "").trim();
      var country = (f.get("country") || "").trim();
      if (!name || !role || !price) { form.reportValidity(); return; }
      var players = load();
      players.push({ name: name, role: role, price: price, country: country });
      save(players);
      form.reset();
      render();
    });
  }

  // animated stat counters
  function animateStats() {
    document.querySelectorAll(".stat .num").forEach(function (el) {
      var target = parseInt(el.getAttribute("data-target"), 10) || 0;
      var start = 0, dur = 1200, t0 = null;
      function step(ts) {
        if (!t0) t0 = ts;
        var prog = Math.min((ts - t0) / dur, 1);
        el.textContent = Math.floor(start + (target - start) * prog);
        if (prog < 1) requestAnimationFrame(step);
      }
      requestAnimationFrame(step);
    });
  }

  render();
  if (document.querySelector(".stat")) animateStats();
})();
