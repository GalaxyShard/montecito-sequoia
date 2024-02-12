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

import { Editor } from 'https://esm.sh/@tiptap/core'
import Document from 'https://esm.sh/@tiptap/extension-document'
import Paragraph from 'https://esm.sh/@tiptap/extension-paragraph'
import Text from 'https://esm.sh/@tiptap/extension-text'
import BulletList from 'https://esm.sh/@tiptap/extension-bullet-list'
import ListItem from 'https://esm.sh/@tiptap/extension-list-item'
import HardBreak from 'https://esm.sh/@tiptap/extension-hard-break'
import Heading from 'https://esm.sh/@tiptap/extension-heading'
import Bold from 'https://esm.sh/@tiptap/extension-bold'
import Italic from 'https://esm.sh/@tiptap/extension-italic'
import Link from 'https://esm.sh/@tiptap/extension-link'

Heading.configure({
    levels: [1, 2, 3, 4, 5],
})

/**
 * @param {HTMLElement} element
 */
function removeElement(element) {

}


/**
 * @param {HTMLElement} cancel
 * @param {string} defaultText
 */
function cancelConfirmation(cancel, defaultText) {
    if (!cancel.dataset.clicked || cancel.dataset.clicked === "false") {
        cancel.dataset.clicked = "true";
        cancel.textContent = "Confirm?";

        setTimeout(() => {
            if (cancel && cancel.dataset.clicked) {
                cancel.dataset.clicked = "false";
                cancel.textContent = defaultText;
            }
        }, 3000);

        return false;
    }
    cancel.dataset.clicked = "false";
    return true;
}



/**
 * @param {() => void} onCancel
 * @param {() => void} onSave
 */
function createToolbar(onCancel, onSave) {
    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let cancel = document.createElement("button");
    cancel.classList.add("editor-cancel");
    cancel.textContent = "Cancel";

    cancel.addEventListener("click", e => {
        if (!cancelConfirmation(cancel, "Cancel")) {
            return;
        }
        onCancel();
    });

    let save = document.createElement("button");
    save.classList.add("editor-save");
    save.textContent = "Save";
    save.addEventListener("click", e => {
        onSave();
    });

    toolbar.append(cancel, save);
    return toolbar;
}



/**
 * @param {HTMLElement} element
 */
function createTextEditor(element) {
    removeHoverToolbar(element);

    let container = document.createElement("div");
    container.classList.add("editor-container");


    function onCancel() {
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
    }
    function onSave() {

    }
    let toolbar = createToolbar(onCancel, onSave);

    let editorElement = document.createElement("div");
    editorElement.classList.add("editor");



    container.dataset.original = element.innerHTML;
    let attributes = [];
    for (const attr of element.attributes) {
        attributes.push([attr.nodeName, attr.nodeValue]);
    }
    container.dataset.attributes = JSON.stringify(attributes);
    container.dataset.tag = element.tagName;

    container.append(editorElement, toolbar);

    let editorInstance = new Editor({
        element: editorElement,
        extensions: [
            Document, Paragraph, Text, BulletList, ListItem, HardBreak, Heading, Bold, Italic, Link
        ],
        content: element.outerHTML,
    })
    element.parentElement.replaceChild(container, element);

    editorInstance.commands.focus("end");
}



/**
 * @param {HTMLImageElement | HTMLElement} element
 */
function createImageEditor(element) {
    removeHoverToolbar(element);
    
    let container = document.createElement("div");
    container.classList.add("editor-container");
    
    let inputLabel = document.createElement("label");
    let input = document.createElement("input");
    input.type = "text";
    
    // getAttribute instead of .src so that the domain name isn't inserted automatically
    let isFittedImage = element.getAttribute("src") == null;

    if (isFittedImage) {
        let src = element.style.getPropertyValue("--image");
        src = src.substring(5, src.length-2); // remove url('____')
        input.value = src;
    } else {
        input.value = element.getAttribute("src");
    }

    function onCancel() {
        let element = document.createElement(container.dataset.tag);

        for (const attr of JSON.parse(container.dataset.attributes)) {
            element.setAttribute(
                attr[0],
                attr[1],
            );
        }
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        
    }
    function onSave() {
        
    }
    let toolbar = createToolbar(onCancel, onSave);

    let attributes = [];
    for (const attr of element.attributes) {
        attributes.push([attr.nodeName, attr.nodeValue]);
    }
    container.dataset.attributes = JSON.stringify(attributes);
    container.dataset.tag = element.tagName;

    inputLabel.append(document.createTextNode("Image Link"), input)
    container.append(inputLabel, toolbar);

    element.parentElement.replaceChild(container, element);
    
    input.focus();
}



/**
 * @param {HTMLImageElement | HTMLElement} element
 */
function createLinkEditor(element) {
    removeHoverToolbar(element);
    
    let container = document.createElement("div");
    container.classList.add("editor-container");
    
    let textLabel = document.createElement("label");
    let text = document.createElement("input");
    text.type = "text";
    text.value = element.textContent;
    
    let linkLabel = document.createElement("label");
    let link = document.createElement("input");
    link.type = "text";
    // getAttribute instead of .href so that the domain name isn't inserted automatically
    link.value = element.getAttribute("href");

    function onCancel() {
        let element = document.createElement("a");
        element.textContent = container.dataset.original;

        for (const attr of JSON.parse(container.dataset.attributes)) {
            element.setAttribute(
                attr[0],
                attr[1],
            );
        }
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        
    }
    function onSave() {
        
    }
    let toolbar = createToolbar(onCancel, onSave);

    let attributes = [];
    for (const attr of element.attributes) {
        attributes.push([attr.nodeName, attr.nodeValue]);
    }
    container.dataset.attributes = JSON.stringify(attributes);
    container.dataset.original = element.textContent;

    textLabel.append(document.createTextNode("Text"), text);
    linkLabel.append(document.createTextNode("Page Link"), link);

    container.append(textLabel, linkLabel, toolbar);

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

    let removeButton = document.createElement("button");
    removeButton.textContent = "Remove";
    removeButton.classList.add("editor-button");
    removeButton.classList.add("editor-cancel");
    removeButton.addEventListener("click", _ => {
        if (!cancelConfirmation(removeButton, "Remove")) {
            return;
        }
        removeElement(element);
    });
    container.append(removeButton);

    if (element.tagName !== "HR") {
        let editButton = document.createElement("button");
        editButton.textContent = "Edit";
        editButton.classList.add("editor-button");
        editButton.addEventListener("click", _ => {
            let tag = element.tagName.toLowerCase();
            if (tag === "img" || tag === "img-fitted") {
                createImageEditor(element);
            } else if (tag === "a") {
                createLinkEditor(element);
            } else {
                createTextEditor(element);
            }
        });
        container.append(editButton);
    }

    let addButton = document.createElement("button");
    addButton.textContent = "Add";
    addButton.classList.add("editor-button");
    addButton.addEventListener("click", _ => {

    });
    container.append(addButton);
    
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
for (let e of document.getElementsByTagName("p")) {
    setupElementEditing(e);
}
for (let e of document.getElementsByTagName("img-fitted")) {
    setupElementEditing(e);
}
for (let e of document.getElementsByTagName("img")) {
    setupElementEditing(e);
}
for (let e of document.getElementsByTagName("hr")) {
    setupElementEditing(e);
}
for (let e of document.getElementsByClassName("link-button-log")) {
    setupElementEditing(e);
}
for (let e of document.querySelectorAll("[data-editable]")) {
    setupElementEditing(e);
}
for (let e of document.querySelectorAll("h1,h2,h3,h4,h5")) {
    setupElementEditing(e);
}