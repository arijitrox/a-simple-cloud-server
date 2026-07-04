/* arijitroy.com — gallery + lightbox (vanilla JS, no deps) */
(function () {
  "use strict";

  /* Photography page: build grid from manifest.json, filter tabs, lightbox */
  var grid = document.getElementById("galleryGrid");
  if (grid) initGallery(grid);

  function initGallery(grid) {
    var photos = [];   // full manifest
    var visible = [];  // currently displayed subset
    var lb = document.getElementById("lightbox");
    var lbImg = lb.querySelector("img");
    var lbCap = lb.querySelector(".lb-cap");
    var current = -1;

    fetch("/assets/photos/manifest.json")
      .then(function (r) { return r.json(); })
      .then(function (data) {
        photos = data;
        render("all");
      })
      .catch(function () {
        grid.innerHTML = "<p>Gallery failed to load — see the full stream on " +
          '<a href="https://www.flickr.com/photos/arigraphy/">Flickr</a>.</p>';
      });

    document.querySelectorAll(".filter-row button").forEach(function (btn) {
      btn.addEventListener("click", function () {
        document.querySelectorAll(".filter-row button").forEach(function (b) {
          b.classList.remove("active");
        });
        btn.classList.add("active");
        render(btn.dataset.album);
      });
    });

    function render(album) {
      visible = album === "all" ? photos.slice() : photos.filter(function (p) {
        return p.album === album;
      });
      grid.innerHTML = "";
      visible.forEach(function (p, i) {
        var a = document.createElement("a");
        a.href = "/assets/photos/full/" + p.id + ".jpg";
        if (p.h > p.w) a.className = "tall";
        var img = document.createElement("img");
        img.src = "/assets/photos/thumbs/" + p.id + ".jpg";
        img.alt = p.title || "Photograph by Arijit Roy";
        img.loading = "lazy";
        var cap = document.createElement("span");
        cap.className = "cap";
        cap.textContent = p.title;
        a.appendChild(img);
        a.appendChild(cap);
        a.addEventListener("click", function (e) {
          e.preventDefault();
          open(i);
        });
        grid.appendChild(a);
      });
    }

    function open(i) {
      current = i;
      var p = visible[i];
      lbImg.src = "/assets/photos/full/" + p.id + ".jpg";
      lbImg.alt = p.title || "";
      lbCap.textContent = p.title + "  ·  " + (i + 1) + "/" + visible.length;
      lb.classList.add("open");
      document.body.style.overflow = "hidden";
    }

    function close() {
      lb.classList.remove("open");
      lbImg.src = "";
      document.body.style.overflow = "";
      current = -1;
    }

    function step(d) {
      if (current < 0) return;
      open((current + d + visible.length) % visible.length);
    }

    lb.querySelector(".lb-close").addEventListener("click", close);
    lb.querySelector(".lb-prev").addEventListener("click", function () { step(-1); });
    lb.querySelector(".lb-next").addEventListener("click", function () { step(1); });
    lb.addEventListener("click", function (e) { if (e.target === lb) close(); });

    document.addEventListener("keydown", function (e) {
      if (!lb.classList.contains("open")) return;
      if (e.key === "Escape") close();
      if (e.key === "ArrowLeft") step(-1);
      if (e.key === "ArrowRight") step(1);
    });
  }
})();
