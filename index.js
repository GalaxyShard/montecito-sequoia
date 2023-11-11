

let primary = true;
let count = 0;
let heroItems = document.getElementById("hero-container").children;

let images = [
    "pow-wow.webp",
    "astronomy.webp",
    "big-baldy.webp",
    "center-dock.webp",
    "mountain-biking.webp",
    "archery.webp",
];

setInterval(() => {
    primary = !primary;
    count++;

    let current;
    let prev;
    if (primary) {
        current = heroItems[0];
        prev = heroItems[1];
    } else {
        current = heroItems[1];
        prev = heroItems[0];
    }
    let nextImg = `assets/hero/${images[count % images.length]}`;
    for (let imgNode of current.children) {
        imgNode.src = nextImg;
    }
    current.classList.add("current");
    prev.classList.remove("current");
}, 4000);