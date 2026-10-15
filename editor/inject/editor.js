/**
 *
 * @licstart  The following is the entire license notice for the
 *  JavaScript code in this page
 *
 * Copyright (C) Dominic Adragna
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

async function sendMessageToApp(body) {
    return await fetch("/editor-post", {
        method: "POST",
        body: body,
    });
}

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

let disableEditor = 0;

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
        if (disableEditor != 0) return;
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

    let isHover = element.classList.contains("editor-hover-element");
    let isSelected = element.classList.contains("editor-selected-element");
    element.classList.remove("editor-hover-element");
    element.classList.remove("editor-selected-element");

    for (const attr of element.attributes) {
        attributes.push([attr.nodeName, attr.nodeValue]);
    }

    if (isHover) {
        element.classList.add("editor-hover-element");
    }
    if (isSelected) {
        element.classList.add("editor-selected-element");
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

let isElementBeingEdited = false;

/**
 * @param {HTMLElement} element
 */
function createTextEditor(element) {
    let serializedLocation = serializePlacementLocation(element);

    let container = document.createElement("div");
    container.classList.add("editor-container");


    function onCancel() {
        let element = document.createElement(container.dataset.tag);
        decodeAttributes(element, container.dataset.attributes);

        element.innerHTML = container.dataset.original;

        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        handleEditorClose(element);
    }

    async function onSave() {
        // convert html into a document fragment
        const html_no_attributes = editorInstance.getHTML();

        let frag = document.createDocumentFragment();
        let temp = document.createElement('div');
        temp.innerHTML = html_no_attributes;

        while (temp.firstChild) {
            frag.appendChild(temp.firstChild);
        }
        temp.remove();
        if (frag.children.length == 0) {
            handleEditorClose(null);
            return;
        }

        decodeAttributes(frag.firstElementChild, container.dataset.attributes);

        let html = "";
        for (let ul of frag.children) {
            if (!tagIs(ul, "UL")) {
                continue;
            }
            for (let li of ul.childNodes) {
                for (let p of li.childNodes) {
                    if (tagIs(p, "P")) {
                        let text = p.innerHTML;
                        li.removeChild(p);
                        li.innerHTML += text;
                    }
                }
            }
        }
        for (let e of frag.children) {
            html += e.outerHTML
                // remove empty elements
                .replace(/<([a-z0-9]+?)><\/([a-z0-9]+?)>/g, "")
                // remove excess whitespace
                .replace(/  +/g, " ")
                .replace(/\n/g, "")
                // put contents of paragraphs, headings, and unordered lists on a newline & indent them
                .replace(/<((p|h[0-9]|ul) ?.+?)>/g, "<$1>\n    ")
                .replace(/<\/((p|h[0-9]|ul))>/g, "\n</$1>\n");
        }

        await sendMessageToApp(serializeCommand("replace-element") + serializedLocation + html + "\n");

        for (let e of frag.children) {
            setupElementEditing(e);
        }

        let prev = container.previousElementSibling;
        let parent = container.parentElement;
        container.parentElement.replaceChild(frag, container);
        if (prev == null) {
            handleEditorClose(parent.firstElementChild);
        } else {
            handleEditorClose(prev.nextElementSibling);
        }
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
    handleEditorOpen();
    element.parentElement.replaceChild(container, element);

    editorInstance.commands.focus("end");
}

/**
 * @param {HTMLImageElement | HTMLElement} element
 */
function createImageEditor(element) {
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
        handleEditorClose(element);
    }
    async function onSave() {
        if (disableEditor != 0) return;
        let element = document.createElement(container.dataset.tag);

        decodeAttributes(element, container.dataset.attributes);
        if (isFittedImage) {
            element.style.setProperty("--image", `url('${input.value}')`);
        } else {
            element.src = input.value;
        }

        await sendMessageToApp(serializeCommand("replace-element") + serializedLocation + serializeElementHtml(element));

        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        handleEditorClose(element);
    }
    let toolbar = createToolbar(onCancel, onSave);
    container.dataset.attributes = encodeAttributes(element);
    container.dataset.tag = element.tagName;

    inputLabel.append(document.createTextNode("Image Link"), input)
    container.append(inputLabel, toolbar);

    handleEditorOpen();
    element.parentElement.replaceChild(container, element);

    input.focus();
}

/**
 * @param {HTMLImageElement | HTMLElement} element
 */
function createLinkEditor(element) {
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

    link.value = element.dataset.originalHref;

    function onCancel() {
        let element = document.createElement("a");
        decodeAttributes(element, container.dataset.attributes);

        element.textContent = container.dataset.original;

        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        handleEditorClose(element);
    }
    async function onSave() {
        if (disableEditor != 0) return;
        let element = document.createElement("a");
        decodeAttributes(element, container.dataset.attributes);

        element.textContent = text.value;

        element.href = "javascript:void(0);";
        element.dataset.originalHref = link.value;

        await sendMessageToApp(serializeCommand("replace-element") + serializedLocation + serializeElementHtml(element));

        setupElementEditing(element);
        container.parentElement.replaceChild(element, container);
        handleEditorClose(element);
    }
    let toolbar = createToolbar(onCancel, onSave);

    container.dataset.attributes = encodeAttributes(element);
    container.dataset.original = element.textContent;

    textLabel.append(document.createTextNode("Text"), text);
    linkLabel.append(document.createTextNode("Page Link"), link);

    container.append(textLabel, linkLabel, toolbar);

    handleEditorOpen();
    element.parentElement.replaceChild(container, element);
}

function createAddElementDropdown() {
    if (disableEditor != 0) return;

    let container = hoverToolbarContainer;
    if (container.getElementsByClassName("editor-dropdown").length > 0) {
        // delete it instead
        container.getElementsByClassName("editor-dropdown")[0].remove();
        return;
    }
    let dropdown = document.createElement("div");
    dropdown.classList.add("editor-toolbar");
    dropdown.classList.add("editor-dropdown");

    async function finalizeAddition(newElement) {
        await sendMessageToApp(serializeCommand("add-element") + serializePlacementLocation(selectedElement) + serializeElementHtml(newElement));

        setupElementEditing(newElement);
        if (newElement.classList.contains("alert")) {
            setupElementEditing(newElement.firstChild); // paragraph
        }
        if (selectedElement.classList.contains("alert")) {
            selectedElement.append(newElement);
        } else {
            selectedElement.insertAdjacentElement("afterend", newElement);
        }
        dropdown.remove();
    }

    let insertAlert = document.createElement("button");
    insertAlert.classList.add("editor-element");
    insertAlert.textContent = "Info Alert";
    insertAlert.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("div");
        e.classList.add("alert", "alert-info");
        e.role = "alert";
        let text = document.createElement("p");
        text.textContent = "Text";
        e.append(text);
        await finalizeAddition(e);
    });
    dropdown.append(insertAlert);


    let insertWarning = document.createElement("button");
    insertWarning.classList.add("editor-element");
    insertWarning.textContent = "Warning Alert";
    insertWarning.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("div");
        e.classList.add("alert", "alert-warning");
        e.role = "alert";
        let text = document.createElement("p");
        text.textContent = "Text";
        e.append(text);
        await finalizeAddition(e);
    });
    dropdown.append(insertWarning);


    let insertImage = document.createElement("button");
    insertImage.classList.add("editor-element");
    insertImage.textContent = "Image";
    insertImage.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("img-fitted");
        e.role = "img";
        e.setAttribute("style", "\n    --image:url('/assets/logos/montecito.svg');\n    --image-max:500px;\n    height:calc(250px + 5vw);\n    border-radius:5px;\n");
        e.setAttribute("aria-label", "");
        await finalizeAddition(e);
    });
    dropdown.append(insertImage);


    let insertLink = document.createElement("button");
    insertLink.classList.add("editor-element");
    insertLink.textContent = "Link";
    insertLink.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("a");
        e.textContent = "Link";
        e.dataset.originalHref = "/";
        e.href = "javascript:void(0);";
        e.classList.add("link-button-log", "link-arrow");
        await finalizeAddition(e);
    });
    dropdown.append(insertLink);


    let insertParagraph = document.createElement("button");
    insertParagraph.classList.add("editor-element");
    insertParagraph.textContent = "Paragraph";
    insertParagraph.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("p");
        e.textContent = "Text";
        await finalizeAddition(e);
    });
    dropdown.append(insertParagraph);


    let insertList = document.createElement("button");
    insertList.classList.add("editor-element");
    insertList.textContent = "Bullet point list";
    insertList.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("ul");
        let li0 = document.createElement("li");
        let li1 = document.createElement("li");
        li0.textContent = "Bullet point 1";
        li1.textContent = "Bullet point 2";
        e.append(li0, li1);
        await finalizeAddition(e);
    });
    dropdown.append(insertList);


    let insertHr = document.createElement("button");
    insertHr.classList.add("editor-element");
    insertHr.textContent = "Horizontal Bar";
    insertHr.addEventListener("click", async _ => {
        if (disableEditor != 0) return;

        let e = document.createElement("hr");
        await finalizeAddition(e);
    });
    dropdown.append(insertHr);

    container.append(dropdown);
}

let selectedElement = null;
let hoverToolbarContainer = null;

/**
 * @param {HTMLElement} element
 */
function deselectSelected() {
    hoverToolbarContainer.classList.add("editor-hover-container-colorless");
    if (selectedElement) {
        selectedElement.classList.remove("editor-selected-element");
        selectedElement = null;
    }
}
function handleEditorOpen() {
    isElementBeingEdited = true;
    selectedElement = null;
    hoverToolbarContainer.classList.add("editor-hover-container-colorless");
}
function handleEditorClose(newElement) {
    isElementBeingEdited = false;
    if (newElement !== null) {
        selectElement(newElement);
    } else {
        selectedElement = null;
        hoverToolbarContainer.classList.add("editor-hover-container-colorless");
    }
}

function toolbarDeactivated() {
    return selectedElement===null || isElementBeingEdited || disableEditor;
}

/**
 * @param {HTMLElement} element
 */
function selectElement(element) {
    if (disableEditor != 0) return;

    element.classList.add("editor-selected-element");
    hoverToolbarContainer.classList.remove("editor-hover-container-colorless");
    selectedElement = element;

    //p, ul, img-fitted, img, hr, link-button-log, alert
    let editButton = hoverToolbarContainer.getElementsByClassName("editor-edit-button")[0];
    if (tagIs(selectedElement, "HR") || selectedElement.classList.contains("alert")) {
        editButton.classList.add("editor-button-deactivated")
    } else {
        editButton.classList.remove("editor-button-deactivated")
    }
}

/**
 * @param {HTMLElement} element
 */
function selectOrRemoveIfSelected(element) {
    if (isElementBeingEdited) {
        return;
    }
    if (selectedElement === element) {
        deselectSelected();
        return;
    }
    deselectSelected();
    selectElement(element);
}

function createHoverToolbar() {
    let container = document.createElement("div");
    hoverToolbarContainer = container;
    container.classList.add("editor-hover-container");
    container.classList.add("editor-hover-container-colorless");

    let toolbar = document.createElement("div");
    toolbar.classList.add("editor-toolbar");

    let removeButton = document.createElement("button");
    removeButton.textContent = "Remove";
    removeButton.classList.add("editor-cancel");
    removeButton.addEventListener("click", async _ => {
        if (toolbarDeactivated()) {
            return;
        }
        if (!cancelConfirmation(removeButton, "Remove")) {
            return;
        }

        await sendMessageToApp(serializeCommand("remove-element") + serializePlacementLocation(selectedElement));
        selectedElement.remove();
        deselectSelected();
    });
    toolbar.append(removeButton);

    let editButton = document.createElement("button");
    editButton.classList.add("editor-element");
    editButton.classList.add("editor-edit-button");
    editButton.textContent = "Edit";
    editButton.addEventListener("click", _ => {
        if (toolbarDeactivated()) {
            return;
        }

        if (tagIs(selectedElement, "IMG", "IMG-FITTED")) {
            createImageEditor(selectedElement);
        } else if (tagIs(selectedElement, "A")) {
            createLinkEditor(selectedElement);
        } else if (tagIs(selectedElement, "HR") || selectedElement.classList.contains("alert")) {
            // not editable
        } else {
            createTextEditor(selectedElement);
        }
    });
    toolbar.append(editButton);

    let downButton = document.createElement("button");
    downButton.textContent = "";
    downButton.classList.add("editor-down-button");

    downButton.addEventListener("click", async _ => {
        if (toolbarDeactivated()) {
            return;
        }

        let nextElement = selectedElement.nextElementSibling;

        if (nextElement) {
            const placeInsideNext = tagIs(nextElement, "DIV", "MAIN", "ASIDE", "SECTION") && !nextElement.classList.contains("row");
            await sendMessageToApp(serializeCommand("move-element") + serializePlacementLocation(selectedElement) + (placeInsideNext ? "in-start\n" : "after\n") + serializePlacementLocation(nextElement));

            if (placeInsideNext) {
                nextElement.insertBefore(selectedElement, nextElement.firstElementChild);
            } else {
                nextElement.insertAdjacentElement("afterend", selectedElement);
            }
        } else {
            if (!tagIs(selectedElement.parentElement, "BODY")
                && (!tagIs(selectedElement.parentElement.parentElement, "BODY") || tagIs(selectedElement, "IMG", "IMG-FITTED"))
                && !selectedElement.parentElement.parentElement.classList.contains("row"))
            {
                // allow moving images up to the body, and anything else up one level but not to the body or out of a column

                await sendMessageToApp(serializeCommand("move-element") + serializePlacementLocation(selectedElement) + "after\n" + serializePlacementLocation(selectedElement.parentElement));

                selectedElement.parentElement.insertAdjacentElement("afterend", selectedElement);
            }
        }
    });
    toolbar.append(downButton);


    let upButton = document.createElement("button");
    upButton.textContent = "";
    upButton.classList.add("editor-up-button");

    upButton.addEventListener("click", async _ => {
        if (toolbarDeactivated()) {
            return;
        }

        let prevElement = selectedElement.previousElementSibling;

        if (prevElement) {
            const placeInsidePrev = tagIs(prevElement, "DIV", "MAIN", "ASIDE", "SECTION") && !prevElement.classList.contains("row");

            await sendMessageToApp(serializeCommand("move-element") + serializePlacementLocation(selectedElement) + (placeInsidePrev ? "in-end\n" : "before\n") + serializePlacementLocation(prevElement));

            if (placeInsidePrev) {
                prevElement.append(selectedElement);
            } else {
                selectedElement.parentElement.insertBefore(selectedElement, prevElement);
            }

        } else if (!tagIs(selectedElement.parentElement, "BODY")
            && (!tagIs(selectedElement.parentElement.parentElement, "BODY") || tagIs(selectedElement, "IMG", "IMG-FITTED"))
            && !selectedElement.parentElement.parentElement.classList.contains("row"))
        {
            // allow moving images up to the body, and anything else up one level but not to the body or out of a column
            await sendMessageToApp(serializeCommand("move-element") + serializePlacementLocation(selectedElement) + "before\n" + serializePlacementLocation(selectedElement.parentElement));

            selectedElement.parentElement.parentElement.insertBefore(selectedElement, selectedElement.parentElement);
        }
    });
    toolbar.append(upButton);


    let addButton = document.createElement("button");
    addButton.classList.add("editor-element");
    addButton.textContent = "Add";
    addButton.addEventListener("click", _ => {
        if (toolbarDeactivated()) {
            return;
        }

        createAddElementDropdown();
    });
    toolbar.append(addButton);

    let gripPoint = null;
    let initialPos = null;
    container.addEventListener("pointerdown", e => {
        gripPoint = [e.clientX, e.clientY];
        initialPos = [parseInt(container.style.right.replace("px", "")), parseInt(container.style.top.replace("px", ""))];
        e.stopPropagation();
    });
    function handlePointerUp(e) {
        gripPoint = null;
        initialPos = null;
        e.stopPropagation();
    }
    container.addEventListener("pointerup", handlePointerUp);
    container.addEventListener("pointercancel", handlePointerUp);

    document.documentElement.addEventListener("pointermove", e => {
        if (gripPoint !== null) {
            container.style.top = (initialPos[1] + e.clientY - gripPoint[1]) + "px";
            container.style.right = (initialPos[0] - e.clientX + gripPoint[0]) + "px";
            e.stopPropagation();
        }
    });

    container.addEventListener("mouseenter", e => {
        if (currentLinkHolder) {
            currentLinkHolder.remove();
            currentLinkHolder = null;
        }
        e.stopPropagation();
    });

    container.style.top = "20px";
    container.style.right = "20px";

    container.append(toolbar);
    document.body.append(container);
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
        if (elements[i].classList.contains("editor")) {
            continue;
        }
        for (let item of elements[i].classList.values()) {
            if (item.startsWith("editor-") && item != "editor-hover-element" && item != "editor-selected-element") {
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
    return element.tagName.toLowerCase() + "\n" + (element.classList.contains("alert") ? "alert" : "not-alert") + "\n" + filesystem_index + "\n";
}

/**
 * @param {string} command
 * @returns {string}
 */
function serializeCommand(command) {
    return command + "\n" + location.href.replace(location.origin, "") + "\n";
}

/**
 * @param {HTMLElement} element
 * @returns {string}
 */
function serializeElementHtml(element) {
    if (tagIs(element, "A")) {
        element.href = element.dataset.originalHref;
        delete element.dataset.originalHref;

    }
    let isHover = element.classList.contains("editor-hover-element");
    let isSelected = element.classList.contains("editor-selected-element");
    element.classList.remove("editor-hover-element");
    element.classList.remove("editor-selected-element");

    let out = element.outerHTML + "\n";

    if (tagIs(element, "A")) {
        // getAttribute instead of .href so that the domain name isn't inserted automatically
        element.dataset.originalHref = element.getAttribute("href");
        element.href = "javascript:void(0);";
    }

    if (isHover) {
        element.classList.add("editor-hover-element");
    }
    if (isSelected) {
        element.classList.add("editor-selected-element");
    }

    return out;
}

let currentLinkHolder = null;

/**
 * @param {HTMLElement} element
 */
function setupElementEditing(element) {
    if (element.dataset.uneditable !== undefined) {
        return;
    }

    if (tagIs(element, "A") && !element.dataset.originalHref) {
        // getAttribute instead of .href so that the domain name isn't inserted automatically
        element.dataset.originalHref = element.getAttribute("href");
        element.href = "javascript:void(0);";
    }

    element.addEventListener("click", e => {
        selectOrRemoveIfSelected(element);
        e.stopPropagation();
    });

    let triggerHover = e => {
        if (isElementBeingEdited || element.classList.contains("editor-hover-element")) {
            return;
        }
        element.classList.add("editor-hover-element");

        if (currentLinkHolder) {
            currentLinkHolder.remove();
            currentLinkHolder = null;
        }

        if (tagIs(element, "A")) {
            let linkHolder = document.createElement("a");
            linkHolder.classList.add("editor-link-holder");
            linkHolder.textContent = "-> Click here to open the link."
            linkHolder.href = element.dataset.originalHref;

            linkHolder.style.left = (element.offsetLeft + element.offsetWidth) + "px";
            linkHolder.style.top = (element.offsetTop - 3 - 5) + "px";
            // linkHolder.style.width = (element.offsetWidth + 3 - 1) + "px";
            element.parentElement.append(linkHolder);

            currentLinkHolder = linkHolder;
        }


        e.stopPropagation();
    };
    element.addEventListener("mouseenter", triggerHover);
    element.addEventListener("mousemove", triggerHover);

    element.addEventListener("mouseleave", e => {
        element.classList.remove("editor-hover-element");
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

createHoverToolbar();
