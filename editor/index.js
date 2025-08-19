/**
 *
 * @licstart  The following is the entire license notice for the
 *  JavaScript code in this page
 *
 * Copyright 2025 Dominic Adragna
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

let frontPage = document.getElementById("front-page");
let hostingPage = document.getElementById("hosting-page");
let hostingPageTitle = document.getElementById("hosting-page-title");
let siteLink = document.getElementById("site-link");

let openProduction = document.getElementById("open-production");
let openEditor = document.getElementById("open-editor");
let backButton = document.getElementById("back-button");

function setPage(page) {
    frontPage.hidden = true;
    hostingPage.hidden = true;

    page.hidden = false;
}
openProduction.addEventListener("click", () => {
    setPage(hostingPage);
    hostingPageTitle.textContent = "Previewing production site";
    siteLink.textContent = "Loading...";

    window.backendHostSite("production").then(info => {
        siteLink.textContent = "http://localhost:" + info.port + "/";
    }).catch(e => {
        siteLink.textContent = "Error loading site: " + e;
    });
});
openEditor.addEventListener("click", () => {
    setPage(hostingPage);
    hostingPageTitle.textContent = "Hosting site with editor";
    siteLink.textContent = "Loading...";

    window.backendHostSite("editor").then(info => {
        siteLink.textContent = "http://localhost:" + info.port + "/";
    }).catch(e => {
        siteLink.textContent = "Error loading site: " + e;
    });
});
backButton.addEventListener("click", () => {
    setPage(frontPage);
    window.backendStopHosting();
});
