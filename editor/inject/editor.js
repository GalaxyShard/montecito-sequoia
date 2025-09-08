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
import { Editor, Mark, mergeAttributes } from '@tiptap/core'
import Document from '@tiptap/extension-document'
import Paragraph from '@tiptap/extension-paragraph'
import Text from '@tiptap/extension-text'
import BulletList from '@tiptap/extension-bullet-list'
import ListItem from '@tiptap/extension-list-item'
import HardBreak from '@tiptap/extension-hard-break'
import Heading from '@tiptap/extension-heading'
import Bold from '@tiptap/extension-bold'
import Italic from '@tiptap/extension-italic'
import Link from '@tiptap/extension-link'

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
 * @param {async () => void} onSave
 */
function createToolbar(onCancel, onSave) {
    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let cancel = document.createElement("button");
    cancel.classList.add("editor-cancel");
    cancel.textContent = "Cancel";

    cancel.addEventListener("click", _ => {
        if (!cancelConfirmation(cancel, "Cancel")) {
            return;
        }
        onCancel();
    });

    let save = document.createElement("button");
    save.classList.add("editor-save");
    save.textContent = "Save";
    save.addEventListener("click", async _ => {
        await onSave();
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

    let serializedLocation = serializePlacementLocation(element);

    let container = document.createElement("div");
    container.classList.add("editor-container");


    function onCancel() {
        let element = document.createElement(container.dataset.tag);
        decodeAttributes(element, container.dataset.attributes);

        element.innerHTML = container.dataset.original;

        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
    }

    async function onSave() {
        // convert html into a document fragment
        const html = editorInstance.getHTML()
            .replace(/<p><\/p>/g, "")
            .replace(/  +/g, "")
            .replace(/\n/g, "")
            .replace(/<p>/g, "<p>\n    ")
            .replace(/<\/p>/g, "\n</p>\n");

        let frag = document.createDocumentFragment();
        let temp = document.createElement('div');
        temp.innerHTML = html;

        while (temp.firstChild) {
            frag.appendChild(temp.firstChild);
        }
        temp.remove();
        if (frag.children.length == 0) {
            return;
        }

        decodeAttributes(frag.firstElementChild, container.dataset.attributes);

        await fetch("/post", {
            method: "POST",
            body: "replace-element\n" + serializedLocation + html + "\n",
        });

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

    let serializedLocation = serializePlacementLocation(element);

    let container = document.createElement("div");
    container.classList.add("editor-container");

    let inputLabel = document.createElement("label");
    let input = document.createElement("input");
    inputLabel.classList.add("editor-element");
    input.classList.add("editor-element");
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
    async function onSave() {
        let element = document.createElement(container.dataset.tag);

        decodeAttributes(element, container.dataset.attributes);
        if (isFittedImage) {
            element.style.setProperty("--image", `url('${input.value}')`);
        } else {
            element.src = input.value;
        }

        await fetch("/post", {
            method: "POST",
            body: "replace-element\n" + serializedLocation + serializeElementHtml(element),
        });

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

    let serializedLocation = serializePlacementLocation(element);

    let container = document.createElement("div");
    container.classList.add("editor-container");

    let textLabel = document.createElement("label");
    let text = document.createElement("input");
    textLabel.classList.add("editor-element");
    text.classList.add("editor-element");
    text.type = "text";
    text.value = element.textContent;

    let linkLabel = document.createElement("label");
    let link = document.createElement("input");
    linkLabel.classList.add("editor-element");
    link.classList.add("editor-element");
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
    async function onSave() {
        let element = document.createElement("a");
        decodeAttributes(element, container.dataset.attributes);

        element.textContent = text.value;
        element.href = link.value;

        await fetch("/post", {
            method: "POST",
            body: "replace-element\n" + serializedLocation + serializeElementHtml(element),
        });

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
    if (container.getElementsByClassName("editor-dropdown").length > 0) {
        return;
    }
    let dropdown = document.createElement("div");
    dropdown.classList.add("editor-toolbar");
    dropdown.classList.add("editor-dropdown");


    let insertAlert = document.createElement("button");
    insertAlert.classList.add("editor-element");
    insertAlert.textContent = "Info Alert";
    insertAlert.addEventListener("click", async _ => {
        let e = document.createElement("div");
        e.classList.add("alert", "alert-info", "text-center", "px-5");
        e.role = "alert";

        await fetch("/post", {
            method: "POST",
            body: "add-element\n" + serializePlacementLocation(element) + serializeElementHtml(e),
        });

        removeHoverToolbar(element);

        setupElementEditing(e);
        element.insertAdjacentElement("afterend", e);

    });
    dropdown.append(insertAlert);


    let insertWarning = document.createElement("button");
    insertWarning.classList.add("editor-element");
    insertWarning.textContent = "Warning Alert";
    insertWarning.addEventListener("click", async _ => {
        let e = document.createElement("div");
        e.classList.add("alert", "alert-warning", "text-center", "px-5");
        e.role = "alert";

        await fetch("/post", {
            method: "POST",
            body: "add-element\n" + serializePlacementLocation(element) + serializeElementHtml(e),
        });

        removeHoverToolbar(element);

        setupElementEditing(e);
        element.insertAdjacentElement("afterend", e);
    });
    dropdown.append(insertWarning);


    let insertImage = document.createElement("button");
    insertImage.classList.add("editor-element");
    insertImage.textContent = "Image";
    insertImage.addEventListener("click", async _ => {
        let e = document.createElement("img-fitted");
        e.role = "img";
        e.setAttribute("style", "\n    --image:url('/assets/logos/montecito.svg');\n    --image-max:500px;\n    height:calc(250px + 5vw);\n    border-radius:5px;\n");
        e.setAttribute("aria-label", "");

        await fetch("/post", {
            method: "POST",
            body: "add-element\n" + serializePlacementLocation(element) + serializeElementHtml(e),
        });

        removeHoverToolbar(element);

        // TODO: accessibility & configuration of images
        setupElementEditing(e);
        if (element.classList.contains("alert")) {
            element.append(e);
        } else {
            element.insertAdjacentElement("afterend", e);
        }
    });
    dropdown.append(insertImage);


    let insertLink = document.createElement("button");
    insertLink.classList.add("editor-element");
    insertLink.textContent = "Link";
    insertLink.addEventListener("click", async _ => {
        let e = document.createElement("a");
        e.textContent = "Link";
        e.href = "/";
        e.classList.add("link-button-log", "link-arrow");

        await fetch("/post", {
            method: "POST",
            body: "add-element\n" + serializePlacementLocation(element) + serializeElementHtml(e),
        });

        removeHoverToolbar(element);

        setupElementEditing(e);
        if (element.classList.contains("alert")) {
            element.append(e);
        } else {
            element.insertAdjacentElement("afterend", e);
        }
    });
    dropdown.append(insertLink);


    let insertParagraph = document.createElement("button");
    insertParagraph.classList.add("editor-element");
    insertParagraph.textContent = "Paragraph";
    insertParagraph.addEventListener("click", async _ => {
        let e = document.createElement("p");
        e.textContent = "Text";

        await fetch("/post", {
            method: "POST",
            body: "add-element\n" + serializePlacementLocation(element) + serializeElementHtml(e),
        });

        removeHoverToolbar(element);

        setupElementEditing(e);
        if (element.classList.contains("alert")) {
            element.append(e);
        } else {
            element.insertAdjacentElement("afterend", e);
        }
    });
    dropdown.append(insertParagraph);


    let insertHr = document.createElement("button");
    insertHr.classList.add("editor-element");
    insertHr.textContent = "Horizontal Bar";
    insertHr.addEventListener("click", async _ => {
        let e = document.createElement("hr");

        await fetch("/post", {
            method: "POST",
            body: "add-element\n" + serializePlacementLocation(element) + serializeElementHtml(e),
        });

        removeHoverToolbar(element);

        setupElementEditing(e);
        element.insertAdjacentElement("afterend", e);
    });
    dropdown.append(insertHr);

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
    removeButton.addEventListener("click", async _ => {
        if (!cancelConfirmation(removeButton, "Remove")) {
            return;
        }

        await fetch("/post", {
            method: "POST",
            body: "remove-element\n" + serializePlacementLocation(element),
        });

        removeHoverToolbar(element);
        element.remove();
    });
    toolbar.append(removeButton);

    if (!tagIs(element, "HR") && !element.classList.contains("alert")) {
        let editButton = document.createElement("button");
        editButton.classList.add("editor-element");
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

    downButton.addEventListener("click", async _ => {
        let nextElement = element.nextElementSibling.nextElementSibling; // skip the toolbar

        if (nextElement) {
            const placeInsideNext = tagIs(nextElement, "DIV", "MAIN", "ASIDE", "SECTION") && !nextElement.classList.contains("row");
            const newPlacementElement = placeInsideNext ? nextElement.firstElementChild : nextElement;
            await fetch("/post", {
                method: "POST",
                body: "move-element\n" + serializePlacementLocation(element) + (placeInsideNext ? "before\n" : "after\n") + serializePlacementLocation(newPlacementElement),
            });

            removeHoverToolbar(element);

            if (placeInsideNext) {
                nextElement.insertBefore(element, nextElement.firstElementChild);
            } else {
                nextElement.insertAdjacentElement("afterend", element);
            }
        } else {
            if (!tagIs(element.parentElement, "BODY")
                && (!tagIs(element.parentElement.parentElement, "BODY") || tagIs(element, "IMG", "IMG-FITTED"))
                && !element.parentElement.parentElement.classList.contains("row"))
            {
                // allow moving images up to the body, and anything else up one level but not to the body or out of a column

                await fetch("/post", {
                    method: "POST",
                    body: "move-element\n" + serializePlacementLocation(element) + "after\n" + serializePlacementLocation(element.parentElement),
                });

                removeHoverToolbar(element);
                element.parentElement.insertAdjacentElement("afterend", element);
            }
        }
    });
    toolbar.append(downButton);


    let upButton = document.createElement("button");
    upButton.textContent = "";
    upButton.classList.add("editor-up-button");

    upButton.addEventListener("click", async _ => {
        let prevElement = element.previousElementSibling;

        if (prevElement) {
            const placeInsidePrev = tagIs(prevElement, "DIV", "MAIN", "ASIDE", "SECTION") && !prevElement.classList.contains("row");
            const newPlacementElement = placeInsidePrev ? prevElement.lastElementChild : prevElement;
            await fetch("/post", {
                method: "POST",
                body: "move-element\n" + serializePlacementLocation(element) + (placeInsidePrev ? "after\n" : "before\n") + serializePlacementLocation(newPlacementElement),
            });

            removeHoverToolbar(element);

            if (placeInsidePrev) {
                prevElement.append(element);
            } else {
                element.parentElement.insertBefore(element, prevElement);
            }

        } else if (!tagIs(element.parentElement, "BODY")
            && (!tagIs(element.parentElement.parentElement, "BODY") || tagIs(element, "IMG", "IMG-FITTED"))
            && !element.parentElement.parentElement.classList.contains("row"))
        {
            // allow moving images up to the body, and anything else up one level but not to the body or out of a column

            await fetch("/post", {
                method: "POST",
                body: "move-element\n" + serializePlacementLocation(element) + "before\n" + serializePlacementLocation(),
            });

            removeHoverToolbar(element);

            element.parentElement.parentElement.insertBefore(element, element.parentElement);
        }
    });
    toolbar.append(upButton);


    let addButton = document.createElement("button");
    addButton.classList.add("editor-element");
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
 * @returns {string}
 */
function serializePlacementLocation(element) {
    let elements = document.getElementsByTagName(element.tagName);
    let filesystem_index = 0;
    let found = false;
    for (let i = 0; i < elements.length; ++i) {
        if (elements[i] == element) {
            found = true;
            break;
        }

        // ignore editor-generated elements
        let count = true;
        if (element.classList.contains("editor")) {
            continue;
        }
        for (let item of element.classList.values()) {
            if (item.startsWith("editor-")) {
                count = false;
                break;
            }
        }

        if (count) {
            filesystem_index += 1;
        }
    }
    if (!found) {
        console.error("fatal: cannot find element in DOM to serialize: " + element.tagName.toLowerCase(), element);
    }
    return location.href.replace(location.origin, "") + "\n" + element.tagName.toLowerCase() + "\n" + (element.classList.contains("alert") ? "alert" : "not-alert") + "\n" + filesystem_index + "\n";
}

/**
 * @param {HTMLElement} element
 * @returns {string}
 */
function serializeElementHtml(element) {
    return element.outerHTML + "\n";
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
