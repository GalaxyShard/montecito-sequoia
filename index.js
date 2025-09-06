/**
 *
 * @licstart  The following is the entire license notice for the 
 *  JavaScript code in this page
 *
 * Copyright (C) 2023-2024 Dominic Adragna
 *
 * The JavaScript code in this page is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * @licend  The above is the entire license notice
 * for the JavaScript code in this page
 *
 */

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

function prepareNextImage() {
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
    let nextImg = `/assets/hero/${images[count % images.length]}`;
    current.style.setProperty("--image", `url(${nextImg})`)
    
    setTimeout(() => {
        current.classList.add("current");
        prev.classList.remove("current");
    }, 2000);
}

setTimeout(() => {
    prepareNextImage();
    setInterval(prepareNextImage, 4000);
}, 1000);
