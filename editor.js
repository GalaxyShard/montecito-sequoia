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
import { Editor, Mark, mergeAttributes } from 'https://cdn.jsdelivr.net/npm/@tiptap/core@2.2.2/+esm'
import Document from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-document@2.2.2/+esm'
import Paragraph from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-paragraph@2.2.2/+esm'
import Text from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-text@2.2.2/+esm'
import BulletList from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-bullet-list@2.2.2/+esm'
import ListItem from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-list-item@2.2.2/+esm'
import HardBreak from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-hard-break@2.2.2/+esm'
import Heading from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-heading@2.2.2/+esm'
import Bold from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-bold@2.2.2/+esm'
import Italic from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-italic@2.2.2/+esm'
import Link from 'https://cdn.jsdelivr.net/npm/@tiptap/extension-link@2.2.2/+esm'

const SmallMark = Mark.create({
    name: "small",
    addOptions() {
      return {
        HTMLAttributes: {},
      };
    },
  
    parseHTML() {
      return [
        {
          tag: 'small',
        },
      ];
    },
    renderHTML({ HTMLAttributes }) {
      return ['small', mergeAttributes(this.options.HTMLAttributes, HTMLAttributes), 0];
    },
});

Heading.configure({
    levels: [1, 2, 3, 4, 5],
})


/**
 * 
 * @param {HTMLElement} element 
 * @param  {...string} tags 
 * @returns 
 */
function tagIs(element, ...tags) {
    return element !== null && tags.includes(element.tagName);
}
/**
 * 
 * @param {HTMLElement} element
 * @param {HTMLElement} child
 */
function insertAfter(element, child) {
    if (child.nextElementSibling) {
        child.parentElement.insertBefore(element, child.nextElementSibling);
    } else {
        child.parentElement.append(element);
    }
}


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
 * @returns {string}
 */
function encodeAttributes(element) {
    let attributes = [];
    for (const attr of element.attributes) {
        attributes.push([attr.nodeName, attr.nodeValue]);
    }
    return JSON.stringify(attributes);
}
/**
 * @param {HTMLElement} element
 * @param {string} attributes
 */
function decodeAttributes(element, attributes) {
    for (const attr of JSON.parse(attributes)) {
        element.setAttribute(
            attr[0],
            attr[1],
        );
    }
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
        decodeAttributes(element, container.dataset.attributes);
        
        element.innerHTML = container.dataset.original;
        
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
    }
    function onSave() {
        // convert html into a document fragment
        const html = editorInstance.getHTML();

        let frag = document.createDocumentFragment();
        let temp = document.createElement('div');
        temp.innerHTML = html;

        while (temp.firstChild) {
            if (temp.firstChild.textContent.length == 0) { // ignore empty paragraphs
                temp.firstChild.remove();
                continue;
            }
            frag.appendChild(temp.firstChild);
        }
        temp.remove();
        if (frag.children.length == 0) {
            return;
        }
        
        decodeAttributes(frag.firstElementChild, container.dataset.attributes);
        for (let e of frag.children) {
            setupElementEditing(e);
        }
        container.parentElement.replaceChild(frag, container);

    }
    let toolbar = createToolbar(onCancel, onSave);

    let editorElement = document.createElement("div");
    editorElement.classList.add("editor");



    container.dataset.original = element.innerHTML;
    container.dataset.attributes = encodeAttributes(element);
    container.dataset.tag = element.tagName;

    container.append(editorElement, toolbar);

    let editorInstance = new Editor({
        element: editorElement,
        extensions: [
            Document, Paragraph, Text, BulletList, ListItem, HardBreak, Heading, Bold, Italic, Link, SmallMark
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

        decodeAttributes(element, container.dataset.attributes);
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
    }
    function onSave() {
        let element = document.createElement(container.dataset.tag);

        decodeAttributes(element, container.dataset.attributes);
        if (isFittedImage) {
            element.style.setProperty("--image", `url('${input.value}')`);
        } else {
            element.src = input.value;
        }

        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
    }
    let toolbar = createToolbar(onCancel, onSave);
    container.dataset.attributes = encodeAttributes(element);
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
        decodeAttributes(element, container.dataset.attributes);

        element.textContent = container.dataset.original;
        
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        
    }
    function onSave() {
        let element = document.createElement("a");
        decodeAttributes(element, container.dataset.attributes);
        
        element.textContent = text.value;
        element.href = link.value;
        
        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        
    }
    let toolbar = createToolbar(onCancel, onSave);

    container.dataset.attributes = encodeAttributes(element);
    container.dataset.original = element.textContent;

    textLabel.append(document.createTextNode("Text"), text);
    linkLabel.append(document.createTextNode("Page Link"), link);

    container.append(textLabel, linkLabel, toolbar);

    element.parentElement.replaceChild(container, element);
}




/**
 * @param {HTMLElement} element
 */
function createAddElementDropdown(element) {
    let container = element.nextElementSibling;
    if (!container || !container.classList.contains("editor-hover-container")) {
        return;
    }
    let dropdown = document.createElement("div");
    dropdown.classList.add("editor-toolbar");
    dropdown.classList.add("editor-dropdown");

    let alertButton = document.createElement("button");
    alertButton.textContent = "Info Alert";
    alertButton.addEventListener("click", _ => {
        
    });
    dropdown.append(alertButton);

    let alertWarningButton = document.createElement("button");
    alertWarningButton.textContent = "Warning Alert";
    alertWarningButton.addEventListener("click", _ => {
        
    });
    dropdown.append(alertWarningButton);

    container.append(dropdown);
}
let currentToolbarElement = null;

/**
 * @param {HTMLElement} element
 */
function removeHoverToolbar(element) {
    let container = element.nextElementSibling;
    if (container && container.classList.contains("editor-hover-container")) {
        container.remove();
        currentToolbarElement = null;
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

    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let removeButton = document.createElement("button");
    removeButton.textContent = "Remove";
    removeButton.classList.add("editor-cancel");
    removeButton.addEventListener("click", _ => {
        if (!cancelConfirmation(removeButton, "Remove")) {
            return;
        }
        removeHoverToolbar(element);
        element.remove();
    });
    toolbar.append(removeButton);

    if (!tagIs(element, "HR") && !element.classList.contains("alert")) {
        let editButton = document.createElement("button");
        editButton.textContent = "Edit";
        editButton.addEventListener("click", _ => {
            if (tagIs(element, "IMG", "IMG-FITTED")) {
                createImageEditor(element);
            } else if (tagIs(element, "A")) {
                createLinkEditor(element);
            } else {
                createTextEditor(element);
            }
        });
        toolbar.append(editButton);
    }
    let downButton = document.createElement("button");
    downButton.textContent = "";
    downButton.classList.add("editor-down-button");

    downButton.addEventListener("click", _ => {
        let nextElement = element.nextElementSibling.nextElementSibling; // skip the toolbar
        
        if (nextElement) {
            removeHoverToolbar(element);
            
            if (tagIs(nextElement, "DIV", "MAIN", "ASIDE", "SECTION") && !nextElement.classList.contains("row")) {
                nextElement.insertBefore(element, nextElement.firstElementChild);
            } else {
                insertAfter(element, nextElement);
            }
        } else {
            if (!tagIs(element.parentElement, "BODY")
                && (!tagIs(element.parentElement.parentElement, "BODY") || tagIs(element, "IMG", "IMG-FITTED"))
                && !element.parentElement.parentElement.classList.contains("row"))
            {
                // allow moving images up to the body, and anything else up one level but not to the body or out of a column
                removeHoverToolbar(element);
                insertAfter(element, element.parentElement);
            }
        }
    });
    toolbar.append(downButton);


    let upButton = document.createElement("button");
    upButton.textContent = "";
    upButton.classList.add("editor-up-button");

    upButton.addEventListener("click", _ => {
        let prevElement = element.previousElementSibling;

        if (prevElement) {
            removeHoverToolbar(element);

            if (tagIs(prevElement, "DIV", "MAIN", "ASIDE", "SECTION") && !prevElement.classList.contains("row")) {
                prevElement.append(element);
            } else {
                element.parentElement.insertBefore(element, prevElement);
            }

        } else if (!tagIs(element.parentElement, "BODY")
            && (!tagIs(element.parentElement.parentElement, "BODY") || tagIs(element, "IMG", "IMG-FITTED"))
            && !element.parentElement.parentElement.classList.contains("row"))
        {
            // allow moving images up to the body, and anything else up one level but not to the body or out of a column
            removeHoverToolbar(element);
            element.parentElement.parentElement.insertBefore(element, element.parentElement);
        }
    });
    toolbar.append(upButton);


    let addButton = document.createElement("button");
    addButton.textContent = "Add";
    addButton.addEventListener("click", _ => {
        createAddElementDropdown(element);
    });
    toolbar.append(addButton);
    

    container.addEventListener("mouseenter", e => {
        e.stopPropagation();
    });
    container.addEventListener("mousemove", e => {
        e.stopPropagation();
    });
    element.classList.add("editor-hover-element");

    container.append(toolbar);
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

    element.addEventListener("mouseenter", e => {
        createHoverToolbar(element);
        e.stopPropagation();
    });
    element.addEventListener("mousemove", e => {
        if (currentToolbarElement !== element) {
            createHoverToolbar(element);
        }
        e.stopPropagation();
    });
}
for (let e of document.getElementsByTagName("p")) {
    setupElementEditing(e);
}
for (let e of document.getElementsByTagName("ul")) {
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
for (let e of document.getElementsByClassName("alert")) {
    setupElementEditing(e);
}
for (let e of document.querySelectorAll("h1,h2,h3,h4,h5")) {
    setupElementEditing(e);
}