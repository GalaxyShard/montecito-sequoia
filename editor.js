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

import "https://cdn.jsdelivr.net/npm/quill@2.0.0-rc.0/dist/quill.js";

/**
 * @param {HTMLElement} element
 */
function removeHoverToolbar(element) {
    let buttons = element.getElementsByClassName("editor-button");
    for (let button of buttons) {
        button.remove();
    }
}
function createEditorBox(element) {
    let container = document.createElement("div");
    container.classList.add("editor-container");

    let editor = document.createElement("div");
    editor.classList.add("editor");



    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let cancel = document.createElement("button");
    cancel.classList.add("editor-cancel");
    cancel.textContent = "Cancel";

    cancel.addEventListener("click", e => {
        if (!cancel.dataset.clicked || cancel.dataset.clicked === "false") {
            cancel.dataset.clicked = "true";
            cancel.textContent = "Confirm";

            setTimeout(() => {
                if (cancel && cancel.dataset.clicked) {
                    cancel.dataset.clicked = "false";
                    cancel.textContent = "Cancel";
                }
            }, 3000);

            return;
        }
        cancel.dataset.clicked = "false";
        let element = document.createElement(container.dataset.originalTag);
        setupElementEditing(element);
        element.innerHTML = container.dataset.original;
        container.parentElement.replaceChild(element, container);
    });

    let save = document.createElement("button");
    save.classList.add("editor-save");
    save.textContent = "Save";
    save.addEventListener("click", e => {

    });



    removeHoverToolbar(element);
    container.dataset.original = element.innerHTML;
    container.dataset.originalTag = element.tagName;
    editor.innerHTML = element.innerHTML;

    toolbar.append(cancel, save);
    container.append(editor, toolbar);
    let _ = new Quill(editor, {
        modules: {
          toolbar: [
            [{ header: [1, 2, 3, 4, 5, false] }],
            ["bold", "italic"],
            ["image", "link"],
            ["clean"],
          ]
        },
        theme: "snow",
    });
    element.parentElement.replaceChild(container, element);
}

/**
 * @param {HTMLElement} element 
 */
function setupElementEditing(element) {
    element.addEventListener("mouseenter", _ => {
        let editButton = document.createElement("button");
        editButton.textContent = "Edit";
        editButton.classList.add("editor-button");
        editButton.addEventListener("click", _ => {
            createEditorBox(element);
        });
        
        element.append(editButton);
    });
    element.addEventListener("mouseleave", _ => {
        removeHoverToolbar(element);
    });
}
for (let p of document.getElementsByTagName("p")) {
    setupElementEditing(p);
}