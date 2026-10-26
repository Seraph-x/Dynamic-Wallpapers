import { basicSetup,EditorState,EditorView,Compartment,javascript,syntaxHighlighting,HighlightStyle,syntaxTree,tags,autocompletion,startCompletion,closeCompletion,search,openSearchPanel,isolateHistory } from './code-editor-api.mjs';
import { completionOptions } from './script-language.mjs';

const normalized=value=>value.replace(/\r\n?/g,'\n');
const highlights=HighlightStyle.define([
  {tag:tags.keyword,color:'var(--code-keyword)'},{tag:[tags.string,tags.regexp],color:'var(--code-string)'},
  {tag:[tags.number,tags.bool,tags.null],color:'var(--code-number)'},{tag:tags.comment,color:'var(--secondary)',fontStyle:'italic'},
]);

export class CodeEditor {
  #view;#t;#onInput;#access=new Compartment();#attributes=new Compartment();#context;#key;#rawSource;#target;#editable=false;#invalid=false;#closed=false;#labelID;#descriptionID;
  constructor(parent,{t,onInput,labelID='script-source-label',descriptionID='script-note script-diagnostics'}) {
    this.#t=t;this.#onInput=onInput;this.#labelID=labelID;this.#descriptionID=descriptionID;
    this.#view=new EditorView({parent,state:this.#state('')});
  }
  #attributesValue(){return {"aria-labelledby":this.#labelID,"aria-describedby":this.#descriptionID,"aria-invalid":String(this.#invalid),"aria-readonly":String(!this.#editable),tabindex:'0',spellcheck:'false',autocapitalize:'off',autocomplete:'off'};}
  #completion(context) {
    if(!this.#editable)return null;
    const node=syntaxTree(context.state).resolveInner(context.pos,-1);
    if(/Comment|String|RegExp|TemplateString/.test(node.name))return null;
    const match=context.matchBefore(/[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\.?/);
    if(!match&&!context.explicit)return null;
    const text=match?.text??'',dot=text.lastIndexOf('.'),scope=dot<0?'':text.slice(0,dot),from=(match?.from??context.pos)+(dot<0?0:dot+1);
    const options=completionOptions(this.#target,scope).map(option=>({...option,apply:(view,completion,start,end)=>{
      if(!this.#editable||view.state.readOnly)return;
      view.dispatch({changes:{from:start,to:end,insert:completion.label},selection:{anchor:start+completion.label.length},userEvent:'input.complete'});
    }}));
    return options.length?{from,options,validFor:/^[\w$]*$/}:null;
  }
  #state(doc) {
    return EditorState.create({doc,extensions:[basicSetup,javascript(),
      EditorState.phrases.of(this.#t.codePhrases),search({top:true}),
      autocompletion({override:[context=>this.#completion(context)]}),
      syntaxHighlighting(highlights),
      this.#access.of([EditorState.readOnly.of(!this.#editable),EditorView.editable.of(this.#editable)]),
      this.#attributes.of(EditorView.contentAttributes.of(this.#attributesValue())),
      EditorView.updateListener.of(update=>{if(update.docChanged)this.#onInput(update.state.doc.toString());}),
      EditorView.theme({'&':{backgroundColor:'var(--field)',color:'var(--text)',fontSize:'12px'},'.cm-scroller':{fontFamily:'var(--mono)',lineHeight:'1.65',overflow:'auto'},'.cm-content':{padding:'8px 0',minHeight:'100%'},'.cm-gutters':{backgroundColor:'var(--surface)',color:'var(--secondary)',borderRight:'1px solid var(--line)'},'&.cm-focused':{outline:'none'},'.cm-activeLine':{backgroundColor:'var(--hover)'},'.cm-activeLineGutter':{backgroundColor:'var(--hover)'},'.cm-selectionBackground':{backgroundColor:'var(--selected)'},'.cm-panels':{backgroundColor:'var(--surface)',color:'var(--text)'},'.cm-tooltip':{backgroundColor:'var(--surface)',color:'var(--text)',border:'1px solid var(--field-line)'},'.cm-tooltip-autocomplete > ul > li[aria-selected]':{backgroundColor:'var(--selected)',color:'var(--text)'}}),
    ]});
  }
  get text(){return this.#view.state.doc.toString();}
  onInput(callback){this.#onInput=callback;}
  setSource(source,context,key,target) {
    this.#target=target;
    const changedContext=this.#context!==context||this.#key!==key;
    const changedRawOnly=this.#rawSource!==source&&normalized(this.#rawSource??'')===normalized(source);
    this.#context=context;this.#key=key;this.#rawSource=source;
    // Own Apply, mark-saved, diagnostics and unrelated edits leave local history
    // intact. A raw-only external replacement also resets it: normalized display
    // text cannot distinguish a project Undo restoring original line endings.
    if(changedContext||changedRawOnly||this.text!==normalized(source))this.#view.setState(this.#state(source));
  }
  setAccess(editable,invalid) {
    const effects=[],accessChanged=this.#editable!==editable;
    if(accessChanged){this.#editable=editable;if(!editable)closeCompletion(this.#view);effects.push(this.#access.reconfigure([EditorState.readOnly.of(!editable),EditorView.editable.of(editable)]));}
    if(accessChanged||this.#invalid!==invalid){this.#invalid=invalid;effects.push(this.#attributes.reconfigure(EditorView.contentAttributes.of(this.#attributesValue())));}
    if(effects.length)this.#view.dispatch({effects});
  }
  complete(){if(this.#closed||!this.#editable)throw new Error(this.#t.codeReadOnly);this.#view.focus();startCompletion(this.#view);}
  find(){if(this.#closed)throw new Error(this.#t.codeReadOnly);openSearchPanel(this.#view);}
  replaceDraft(source) {
    if(this.#closed||!this.#editable)throw new Error(this.#t.codeReadOnly);
    this.#view.dispatch({changes:{from:0,to:this.#view.state.doc.length,insert:normalized(source)},selection:{anchor:0},userEvent:'input.template',annotations:isolateHistory.of('full')});this.#view.focus();
  }
  reveal(location,{focus=true}={}){if(this.#closed)throw new Error(this.#t.codeReadOnly);if(location.available)this.#view.dispatch({selection:{anchor:location.from,head:location.to},effects:EditorView.scrollIntoView(location.from,{y:'center'})});if(focus)this.#view.focus();}
  destroy(){this.#closed=true;this.#view.destroy();}
}
