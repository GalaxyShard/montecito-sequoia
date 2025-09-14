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
let backupsPage = document.getElementById("manage-backups-page");

let hostingPageTitle = document.getElementById("hosting-page-title");
let hostingStatus = document.getElementById("hosting-status");
let copyLink = document.getElementById("copy-link");
let linkButtons = document.getElementById("link-buttons");

let openProduction = document.getElementById("open-production");
let openEditor = document.getElementById("open-editor");
let manageBackups = document.getElementById("manage-backups");
let backButtons = document.getElementsByClassName("back-button");

let makeBackup = document.getElementById("make-backup");
let restoreBackup = document.getElementById("restore-backup");
let deleteBackup = document.getElementById("delete-backup");
let backupsStatus = document.getElementById("backups-status");
let backupsList = document.getElementById("backups-list");

let selectedBackupEntry = null;

function setPage(page) {
    frontPage.hidden = true;
    hostingPage.hidden = true;
    backupsPage.hidden = true;

    linkButtons.hidden = true;

    page.hidden = false;
}
openProduction.addEventListener("click", () => {
    setPage(hostingPage);
    hostingPageTitle.textContent = "Previewing production site";
    hostingStatus.textContent = "Loading...";

    window.backendHostSite("production").then(info => {
        hostingStatus.textContent = "http://localhost:" + info.port + "/";
        linkButtons.hidden = false;
    }).catch(e => {
        hostingStatus.textContent = "Error loading site: " + e;
    });
});
openEditor.addEventListener("click", () => {
    setPage(hostingPage);
    hostingPageTitle.textContent = "Hosting site with editor";
    hostingStatus.textContent = "Loading...";

    window.backendHostSite("editor").then(info => {
        hostingStatus.textContent = "http://localhost:" + info.port + "/";
        linkButtons.hidden = false;
    }).catch(e => {
        hostingStatus.textContent = "Error loading site: " + e;
    });
});

manageBackups.addEventListener("click", () => {
    setPage(backupsPage);
    refreshBackupsList();
});
function refreshBackupsList() {
    selectedBackupEntry = null;
    while (backupsList.firstChild) {
        backupsList.removeChild(backupsList.lastChild);
    }
    backupsStatus.textContent = "Loading backups...";

    window.backendRetrieveBackups().then(listing => {
        for (let entry of listing) {
            let container = document.createElement("button");
            container.classList.add("backup-entry");
            // note: intentionally not a global regex replacement (/backup-/g); should only replace first occurance (in the beginning of the string)
            container.textContent = entry.replace("backup-", "");
            container.dataset.entryName = entry;

            container.addEventListener("click", () => {
                if (selectedBackupEntry !== null) {
                    selectedBackupEntry.classList.remove("selected");
                }
                if (selectedBackupEntry === container) {
                    container.classList.remove("selected");
                    selectedBackupEntry = null;
                } else {
                    selectedBackupEntry = container;
                    selectedBackupEntry.classList.add("selected");
                }
            });
            backupsList.append(container);
        }
        backupsStatus.textContent = "Loaded backups";
    }).catch(e => {
        backupsStatus.textContent = "Failed to load backups: " + e;
    });
}

makeBackup.addEventListener("click", () => {
    backupsStatus.textContent = "Making backup from master copy...";
    window.backendMakeBackup().then(() => {
        backupsStatus.textContent = "Successfully backed up";
        refreshBackupsList();
    }).catch(e => {
        backupsStatus.textContent = "Failed to backup: " + e;
    });
});

restoreBackup.addEventListener("click", () => {
    backupsStatus.textContent = "Restoring backup...";
    if (selectedBackupEntry === null) {
        backupsStatus.textContent = "No backup selected (click one to select)";
        return;
    }
    window.backendRestoreBackup(selectedBackupEntry.dataset.entryName).then(() => {
        backupsStatus.textContent = "Successfully restored backup";
    }).catch(e => {
        backupsStatus.textContent = "Failed to restore backup: " + e;
    });
});

deleteBackup.addEventListener("click", () => {
    backupsStatus.textContent = "Deleting backup...";
    if (selectedBackupEntry === null) {
        backupsStatus.textContent = "No backup selected (click one to select)";
        return;
    }
    window.backendDeleteBackup(selectedBackupEntry.dataset.entryName).then(() => {
        backupsStatus.textContent = "Successfully deleted backup";
        refreshBackupsList();
    }).catch(e => {
        backupsStatus.textContent = "Failed to delete backup: " + e;
    });
});

for (let button of backButtons) {
    button.addEventListener("click", () => {
        setPage(frontPage);
        window.backendStopHosting();
    });
}

copyLink.addEventListener("click", () => {
    let url = hostingStatus.textContent;
    if (!url.startsWith("http")) {
        return;
    }

    // TypeError: undefined is not an object (evaluating 'navigator.clipboard.writeText')
    // navigator.clipboard.writeText(url);

    window.backendCopyToClipboard(url);
});
