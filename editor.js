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

const Parchment = Quill.import("parchment");
const QuillImports = {
    block: Quill.import("blots/block"),
    break: Quill.import("blots/break"),
    container: Quill.import("blots/container"),
    cursor: Quill.import("blots/cursor"),
    inline: Quill.import("blots/inline"),
    scroll: Quill.import("blots/scroll"),
    text: Quill.import("blots/text"),

    bold: Quill.import("formats/bold"),
    italic: Quill.import("formats/italic"),
    link: Quill.import("formats/link"),
    header: Quill.import("formats/header"),
}

const generalRegistry = new Parchment.Registry();
generalRegistry.register(
    QuillImports.block,
    QuillImports.break,
    QuillImports.container,
    QuillImports.cursor,
    QuillImports.inline,
    QuillImports.scroll,
    QuillImports.text,

    QuillImports.bold,
    QuillImports.italic,
    QuillImports.link,
    QuillImports.header,
);

/**
 * @param {HTMLElement} element
 */
function createEditorBox(element) {
    removeHoverToolbar(element);

    let container = document.createElement("div");
    container.classList.add("editor-container");

    let editor = document.createElement("div");
    editor.classList.add("editor");
    
    let contents = document.createElement(element.tagName);
    if (element.href) contents.href = element.href;
    if (element.id) contents.id = element.id;
    if (element.dataset.uneditable) contents.dataset.uneditable = element.dataset.uneditable;
    contents.innerHTML = element.innerHTML.trim();
    editor.append(contents);


    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let cancel = document.createElement("button");
    cancel.classList.add("editor-cancel");
    cancel.textContent = "Cancel";

    cancel.addEventListener("click", e => {
        if (!cancel.dataset.clicked || cancel.dataset.clicked === "false") {
            cancel.dataset.clicked = "true";
            cancel.textContent = "Confirm?";

            setTimeout(() => {
                if (cancel && cancel.dataset.clicked) {
                    cancel.dataset.clicked = "false";
                    cancel.textContent = "Cancel";
                }
            }, 3000);

            return;
        }
        cancel.dataset.clicked = "false";
        let element = document.createElement(container.dataset.tag);
        
        element.innerHTML = container.dataset.original;
        for (const attr of JSON.parse(container.dataset.attributes)) {
            element.setAttribute(
                attr[0],
                attr[1],
            );
        }
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
    });

    let save = document.createElement("button");
    save.classList.add("editor-save");
    save.textContent = "Save";
    save.addEventListener("click", e => {

    });



    container.dataset.original = element.innerHTML;
    let attributes = [];
    for (const attr of element.attributes) {
        attributes.push([attr.nodeName, attr.nodeValue]);
    }
    container.dataset.attributes = JSON.stringify(attributes);
    container.dataset.tag = element.tagName;

    toolbar.append(cancel, save);
    container.append(editor, toolbar);
    
    let _ = new Quill(editor, {
        modules: {
          toolbar: [
            [{ header: [1, 2, 3, 4, 5, false] }],
            ["bold", "italic", "link"],
            ["clean"],
          ]
        },
        registry: generalRegistry,
        theme: "snow",
    });
    element.parentElement.replaceChild(container, element);
}



let currentToolbarElement = null;

/**
 * @param {HTMLElement} element
 */
function removeHoverToolbar(element) {
    let container = element.nextElementSibling;
    if (container && container.classList.contains("editor-hover-container")) {
        container.remove();
    }
    element.classList.remove("editor-hover-element");
}

/**
 * @param {HTMLElement} element
 */
function createHoverToolbar(element) {
    if (element.classList.contains("editor-hover-element")) {
        return;
    }

    let container = document.createElement("div");
    container.classList.add("editor-hover-container");
    container.classList.add("editor-toolbar");

    let editButton = document.createElement("button");
    editButton.textContent = "Edit";
    editButton.classList.add("editor-button");
    editButton.addEventListener("click", _ => {
        createEditorBox(element);
    });
    
    container.append(editButton);
    element.classList.add("editor-hover-element");
    element.insertAdjacentElement("afterend", container);
    
    if (currentToolbarElement !== null) {
        removeHoverToolbar(currentToolbarElement);
    }
    currentToolbarElement = element;
}

/**
 * @param {HTMLElement} element 
 */
function setupElementEditing(element) {
    if (element.dataset.uneditable !== undefined) {
        return;
    }

    element.addEventListener("mouseenter", _ => {
        createHoverToolbar(element);
    });
}
for (let p of document.getElementsByTagName("p")) {
    setupElementEditing(p);
}
for (let e of document.getElementsByClassName("link-button-log")) {
    setupElementEditing(e);
}
for (let e of document.querySelectorAll("[data-editable]")) {
    setupElementEditing(e);
}
for (let h of document.querySelectorAll("h1,h2,h3,h4,h5")) {
    setupElementEditing(h);
}