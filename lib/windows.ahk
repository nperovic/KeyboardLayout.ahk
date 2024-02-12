/************************************************************************
 * @author Lexikos
 * @see https://github.com/Lexikos/winrt.ahk
 ***********************************************************************/
class FFITypes
{
    static NumTypeSize := Map()
    static __new()
    {
        for t in [
            [1, 'Int8', 'char'],  ; Int8 is not used in WinRT, but maybe Win32metadata.
            [1, 'UInt8', 'uchar'],
            [2, 'Int16', 'short'],
            [2, 'UInt16', 'ushort'],
            [4, 'Int32', 'int'],
            [4, 'UInt32', 'uint'],
            [8, 'Int64', 'int64'],
            [8, 'UInt64', 'uint64'],
            [4, 'Single', 'float'],
            [8, 'Double', 'double'],
            [A_PtrSize, 'IntPtr', 'ptr'],
        ]
        {
            this.NumTypeSize[t[3]] := t[1]
            this.%t[2]% := NumberTypeInfo(t*)
        }
        for t in ['Attribute', 'Void']
        {
            this.%t% := BasicTypeInfo(t)
        }
    }
}

class RtRootTypes extends FFITypes
{
    static __new()
    {
        t := [
            ['Attribute', {
                TypeClass: RtTypeInfo.Attribute,
            }],
            ['Boolean', {
                ArgPassInfo: ArgPassInfo("char", v => !!v, Number),
            }],
            ['Char16', {
                ArgPassInfo: ArgPassInfo("ushort", Ord, Chr),
            }],
            ['Delegate', {
                TypeClass: RtTypeInfo.Delegate,
            }],
            ['Enum', {
                TypeClass: RtTypeInfo.Enum,
                Class: EnumValue,
            }],
            ['Guid', {
                Class: GUID,
                Size: 16
            }],
            ['Interface', {
                TypeClass: RtTypeInfo.Interface,
                Class: RtObject,
            }],
            ['Object', {
                TypeClass: RtTypeInfo.Object,
                ArgPassInfo: RtInterfaceArgPassInfo(),
                ReadWriteInfo: RtInterfaceReadWriteInfo(),
                Class: RtObject,
            }],
            ['String', {
                ArgPassInfo: ArgPassInfo("ptr", HStringFromString, HStringRet),
                ReadWriteInfo: ReadWriteInfo.FromClass(HString),
            }],
            ['Struct', {
                TypeClass: RtTypeInfo.Struct,
            }],
        ]
        for t in t
        {
            bti := this.%t[1]% := BasicTypeInfo(t*)
            if t[2].HasProp('TypeClass')
                t[2].TypeClass.Prototype.FundamentalType := bti
        }
    }
}

class BasicTypeInfo
{
    __new(name, props := unset)
    {
        this.Name := name
        if IsSet(props)
            for name, value in props.OwnProps()
                this.%name% := value
    }
    ToString() => this.Name
    FundamentalType => this
    static prototype.ArgPassInfo := false
    static prototype.ReadWriteInfo := false
}

class NumberTypeInfo extends BasicTypeInfo
{
    __new(size, name, nt)
    {
        this.Name := name
        this.Size := size
        this.ReadWriteInfo := ReadWriteInfo.FromArgPassInfo(
            this.ArgPassInfo := ArgPassInfo(nt, false, false)
        )
    }
}

class ArgPassInfo
{
    /*
    ScriptToNative := (scriptValue) => nativeValue
    NativeToScript := (nativeValue) => scriptValue
    NativeType := Ptr | Int | UInt | ...
    */
    __new(nt, stn, nts)
    {
        this.NativeType := nt
        this.ScriptToNative := stn
        this.NativeToScript := nts
    }

    static Unsupported := this('Unsupported', false, false)
}

class ReadWriteInfo
{
    /*
    GetReader(offset:=0)
    GetWriter(offset:=0)
    GetDeleter(offset:=0)
    Size => Integer
    */

    static ForType(typeinfo)
    {
        return typeinfo.ReadWriteInfo
            || (api := typeinfo.ArgPassInfo) && this.FromArgPassInfo(api)
            || this.FromClass(typeinfo.Class)
    }

    class FromArgPassInfo extends ReadWriteInfo
    {
        __new(api)
        {
            this.api := api
            this.Size := FFITypes.NumTypeSize[api.NativeType]
        }

        GetReader(offset := 0) => (
            f := this.api.NativeToScript,
            nt := this.api.NativeType,
            f ? (ptr) => f(NumGet(ptr, offset, nt))
            : (ptr) => (NumGet(ptr, offset, nt)))

        GetWriter(offset := 0) => (
            f := this.api.ScriptToNative,
            nt := this.api.NativeType,
            f ? (ptr, value) => NumPut(nt, f(value), ptr, offset)
            : (ptr, value) => NumPut(nt, (value), ptr, offset))

        GetDeleter(offset := 0) => false
    }

    class FromClass extends ReadWriteInfo
    {
        __new(cls)
        {
            this.Class := cls
            this.Size := cls.HasProp('Size') ? cls.Size : cls.Prototype.Size
            cls.HasProp('Align') && this.Align := cls.Align
        }

        GetReader(offset := 0) => this.Class.FromOffset.Bind(this.Class, , offset)

        GetWriter(offset := 0)
        {
            cls := this.Class
            ; TODO: implement struct coercion
            copyToPtr := (checkType := !cls.HasProp('CopyToPtr'))
                ? cls.Prototype.CopyToPtr  ; do not use an overridden method if subclassed
                : cls.CopyToPtr.Bind(cls)
            struct_writer(buf, value)
            {
                if checkType && !(value is cls)
                    throw TypeError('Expected ' cls.Prototype.__class ' but got ' Type(value) '.', -1)
                copyToPtr(value, buf.ptr + offset)
            }
            return struct_writer
        }

        GetDeleter(offset := 0)
        {
            cls := this.Class
            if !cls.Prototype.HasMethod('__delete')
                return false
            ; del := cls.Prototype.__delete
            ; return struct_delete_at_offset(buf) => del({ptr: buf.ptr + offset})
            proto := cls.Prototype
            ; FIXME: assumes all types other than ValueType are pointer types
            if HasBase(proto, ValueType.Prototype)
                return struct_delete_at_offset(buf) => ({ ptr: buf.ptr + offset, base: proto }, "")
            else
                return ptr_delete_at_offset(buf) => ({ ptr: NumGet(buf.ptr, offset, 'ptr'), base: proto }, "")
        }
    }
}

class RtInterfaceArgPassInfo extends ArgPassInfo
{
    __new(typeinfo := unset)
    {
        ; _rt_WrapInspectable attempts to get the runtime class (at runtime) to make
        ; all methods available.  It sometimes fails for generic interfaces, so pass
        ; typeinfo as a default type to wrap.
        ; TODO: type checking for ScriptToNative
        super.__new("ptr", false,
            IsSet(typeinfo) ? _rt_WrapInspectable.Bind(, typeinfo) : _rt_WrapInspectable
        )
    }
}

class RtInterfaceReadWriteInfo extends ReadWriteInfo
{
    __new(typeinfo := false)
    {
        this.typeinfo := typeinfo
        this.Size := A_PtrSize
    }

    GetReader(offset := 0) => (ptr) => (
        p := NumGet(ptr, offset, "ptr"),
        ObjAddRef(p),
        _rt_WrapInspectable(p, this.typeinfo)
    )

    GetWriter(offset := 0) => (ptr, value) => (
        ; TODO: type checking
        ObjAddRef(pnew := value.ptr),
        (pold := NumGet(ptr, offset, "ptr")) && ObjRelease(pold),
        NumPut("ptr", pnew, ptr, offset)
    )

    ; Objects aren't supposed to be allowed in structs, but the HttpProgress struct
    ; has an IReference<UInt64>, which projects to C# as System.Nullable<ulong> but
    ; really is an interface pointer.
    GetDeleter(offset := 0) => (ptr) => (
        (p := NumGet(ptr, offset, "ptr")) && ObjRelease(p)
    )
}

class RtObjectArgPassInfo extends ArgPassInfo
{
    __new(typeinfo)
    {
        local proto
        super.__new("ptr",
            false, ; TODO: type checking for ScriptToNative
            ; For composable classes, check class at runtime.
            !typeinfo.IsSealed ? _rt_WrapInspectable.Bind(, typeinfo) :
            ; For sealed classes, class is already known.
            rt_wrapSpecificClass(p) => p && {
                ptr: p,
                base: IsSet(proto) ? proto : proto := typeinfo.Class.prototype
            }
        )
    }
}

class RtEnumArgPassInfo extends ArgPassInfo
{
    __new(typeinfo)
    {
        cls := typeinfo.Class
        super.__new(
            cls.__basicType.ArgPassInfo.NativeType,
            cls.Parse.Bind(cls),
            cls
        )
    }
}

class RtDelegateArgPassInfo extends ArgPassInfo
{
    __new(typeinfo)
    {
        if !typeinfo.HasProp('Factory')
        {
            methods := [typeinfo.Methods()*]
            if methods.Length != 2 || (methods[1].Name '|' methods[2].Name) != '.ctor|Invoke'
                throw Error('Unexpected delegate typeinfo')
            method := methods[2] ; Invoke
            types := typeinfo.MethodArgTypes(method.sig)
            factory := DelegateFactory(typeinfo.GUID, types, types.RemoveAt(1))
            typeinfo.DefineProp('Factory', { value: factory })
        }
        else
            factory := typeinfo.Factory
        super.__new("ptr", factory, false)  ; TODO: delegate NativeToScript (e.g. for IAsyncOperation.Completed return value)
    }
}


AddMethodOverloadTo(obj, name, f, name_prefix:="") {
    if obj.HasOwnProp(name) {
        if (pd := obj.GetOwnPropDesc(name)).HasProp('Call')
            prev := pd.Call
    }
    if IsSet(prev) {
        if !((of := prev) is OverloadedFunc) {
            obj.DefineProp(name, {Call: of := OverloadedFunc()})
            of.Name := name_prefix . name
            of.Add(prev)
        }
        of.Add(f)
    }
    else
        obj.DefineProp(name, {Call: f})
}

class OverloadedFunc {
    m := Map()
    Add(f) {
        n := f.MinParams
        Loop (f.MaxParams - n) + 1
            if this.m.has(n)
                throw Error("Ambiguous function overloads", -1)
            else
                this.m[n++] := f
    }
    Call(p*) {
        if (f := this.m.get(p.Length, 0))
            return f(p*)
        else
            throw Error(Format('Overloaded function "{}" does not accept {} parameters.'
                , this.Name, p.Length), -1)
    }
    static __new() {
        this.prototype.Name := ""
    }
}



class GUID {
    __new(sguid:=unset) {
        this.Ptr := DllCall("msvcrt\malloc", "ptr", 16, "cdecl ptr")
        if IsSet(sguid)
            DllCall("ole32.dll\IIDFromString", "wstr", sguid, "ptr", this, "hresult")
        else
            NumPut("int64", 0, "int64", 0, this)
    }
    
    __delete() => DllCall("msvcrt\free", "ptr", this, "cdecl")
    
    static __new() {
        this.Prototype.DefineProp 'ToString', {call: GuidToString}
    }
    
    static prototype.Size := 16
}

GuidToString(guid) {
    buf := Buffer(78)
    DllCall("ole32.dll\StringFromGUID2", "ptr", guid, "ptr", buf, "int", 39)
    return StrGet(buf, "UTF-16")
}


; Wraps a HSTRING.  Takes ownership of the handle it is given.
class HString {
	__new(hstr := 0) => this.ptr := hstr
	static __new() {
        this.Prototype.DefineProp 'ToString', {call: WindowsGetString}
        this.Prototype.DefineProp '__delete', {call: WindowsDeleteString}
        this.Size := A_PtrSize
    }
    static FromOffset(buf, offset) {
        return WindowsGetString(NumGet(buf, offset, 'ptr'))
    }
    static CopyToPtr(value, ptr) {
        WindowsDeleteString(NumGet(ptr, 'ptr'))
        NumPut('ptr', WindowsCreateString(String(value)), ptr)
    }
}

; Create HString for passing to ComCall/DllCall.  Has automatic cleanup.
HStringFromString(str) => HString(WindowsCreateString(String(str)))

; Delete a HString and return the equivalent string value.
HStringRet(hstr) { ; => String(HString(hstr))
	s := DllCall("combase.dll\WindowsGetStringRawBuffer", "ptr", hstr, "uint*", &len:=0, "ptr")
	s := StrGet(s, -len, "UTF-16")
    DllCall("combase.dll\WindowsDeleteString", "ptr", hstr)
    return s
}

; Create a raw HSTRING and return the handle.
WindowsCreateString(str, len := unset) {
    DllCall("combase.dll\WindowsCreateString"
			, "ptr", StrPtr(str), "uint", IsSet(len) ? len : StrLen(str)
            , "ptr*", &hstr := 0, "hresult")
    return hstr
}

; Get the string value of a HSTRING.
WindowsGetString(hstr, &len := 0) {
	p := DllCall("combase.dll\WindowsGetStringRawBuffer"
		, "ptr", hstr, "uint*", &len := 0, "ptr")
	return StrGet(p, -len, "UTF-16")
}

; Delete a HSTRING.
WindowsDeleteString(hstr) {
    ; api-ms-win-core-winrt-string-l1-1-0.dll
    ; hstr or hstr.ptr can be 0 (equivalent to "").
    DllCall("combase.dll\WindowsDeleteString", "ptr", hstr)
}




class MetaDataModule {
    static MAX_NAME_CCH := 1024

    ptr := 0
    __delete() {
        (p := this.ptr) && ObjRelease(p)
    }
    StaticAttr => _rt_CacheAttributeCtors(this, this, 'StaticAttr')
    FactoryAttr => _rt_CacheAttributeCtors(this, this, 'FactoryAttr')
    ActivatableAttr => _rt_CacheAttributeCtors(this, this, 'ActivatableAttr')
    ComposableAttr => _rt_CacheAttributeCtors(this, this, 'ComposableAttr')
    
    ObjectTypeRef => _rt_memoize(this, 'ObjectTypeRef')
    _init_ObjectTypeRef() {
        mdai := ComObjQuery(this, "{EE62470B-E94B-424e-9B7C-2F00C9249F93}") ; IID_IMetaDataAssemblyImport
        asm := _rt_FindAssemblyRef(mdai, "mscorlib") || 1
        ; FindTypeRef
        if ComCall(55, this, "uint", asm, "wstr", "System.Object", "uint*", &tr:=0, "int") != 0 {
            ; System.Object not found
            ; @Debug-Breakpoint
            return -1
        }
        return tr
    }
    
    AddFactoriesToWrapper(w, t) {
        if t.HasIActivationFactory {
            this.AddIActivationFactoryToWrapper(w)
        }
        for f in t.Factories() {
            this.AddInterfaceToWrapper(w, f, false, "Call")
        }
        for f in t.Composers() {
            this.AddInterfaceToWrapper(w, f, false, "Call")
            if w.HasOwnProp("Call")
                AddMethodOverloadTo(w, "Call", w => w(0, 0), w.prototype.__class ".")
        }
    }
    
    AddIActivationFactoryToWrapper(w) {
        ActivateInstance(cls) {
            ComCall(6, ComObjQuery(cls, "{00000035-0000-0000-C000-000000000046}") ; IActivationFactory
                , "ptr*", inst := {base: cls.prototype})
            return inst
        }
        AddMethodOverloadTo(w, "Call", ActivateInstance, w.prototype.__class ".")
    }
    
    CreateInterfaceWrapper(t) {
        w := _rt_CreateClass(t_name := t.Name, RtObject)
        t.DefineProp 'Class', {value: w}
        this.AddInterfaceToWrapper(w.prototype, t, true)
        wrapped := Map()
        addreq(w.prototype, t)
        addreq(w, t) {
            for ti in t.Implements() {
                if wrapped.Has(ti_name := ti.Name)
                    continue
                wrapped[ti_name] := true
                ti.m.AddInterfaceToWrapper(w, ti, false)
                addreq(w, ti)
            }
        }
        return w
    }
    
    CreateClassWrapper(t) {
        w := _rt_CreateClass(classname := t.Name, t.SuperType.Class)
        t.DefineProp 'Class', {value: w}
        ; Add any constructors:
        this.AddFactoriesToWrapper(w, t)
        ; Add static interfaces to the class:
        for ti in t.Statics() {
            this.AddInterfaceToWrapper(w, ti)
        }
        ; Need a factory?
        if ObjOwnPropCount(w) > 1 {
            static oiid := GUID("{AF86E2E0-B12D-4c6a-9C5A-D7AA65101E90}") ; IInspectable
            hr := DllCall("combase.dll\RoGetActivationFactory"
                , "ptr", HStringFromString(classname)
                , "ptr", oiid
                , "ptr*", w, "hresult")
        }
        wrapped := Map()
        addRequiredInterfaces(wp, t, isclass) {
            for ti, impl in t.Implements() {
                ; GetCustomAttributeByName
                isdefault := isclass && ComCall(60, this, "uint", impl
                    , "wstr", "Windows.Foundation.Metadata.DefaultAttribute"
                    , "ptr", 0, "ptr", 0) = 0
                if isdefault {
                    ; This is currently assigned to the Class and not t so that
                    ; t.Class.__DefaultInterface will cause this code to execute
                    ; if needed (i.e. if the class hasn't been wrapped yet).
                    w.DefineProp '__DefaultInterface', {value: ti}
                }
                if wrapped.has(ti_name := ti.Name)
                    continue
                wrapped[ti_name] := true
                ti.m.AddInterfaceToWrapper(wp, ti, isdefault)
                ; Interfaces "required" by ti are also implemented by the class
                ; even if it doesn't "require" them directly (sometimes it does).
                addRequiredInterfaces(wp, ti, false)
            }
        }
        ; Add instance interfaces:
        addRequiredInterfaces(w.prototype, t, true)
        return w
    }
    
    AddInterfaceToWrapper(w, t, isdefault:=false, nameoverride:=false) {
        pguid := t.GUID
        if !pguid {
            ; @Debug-Output => Interface {t.Name} can't be added because it has no GUID
            return
        }
        namebuf := Buffer(2*MetaDataModule.MAX_NAME_CCH)
        DllCall("ole32\StringFromGUID2", "ptr", pguid, "ptr", namebuf, "int", MetaDataModule.MAX_NAME_CCH)
        iid := StrGet(namebuf)
        name_prefix := w.HasOwnProp('prototype') ? w.prototype.__class "." : w.__class ".Prototype."
        for method in t.Methods() {
            name := nameoverride ? nameoverride : method.name
            types := t.MethodArgTypes(method.sig)
            wrapper := MethodWrapper(5 + A_Index, iid, types, name_prefix name)
            if method.flags & 0x400 { ; tdSpecialName
                switch SubStr(name, 1, 4) {
                case "get_":
                    w.DefineProp(SubStr(name, 5), {Get: wrapper})
                    continue
                case "put_":
                    w.DefineProp(SubStr(name, 5), {Set: wrapper})
                    continue
                }
            }
            AddMethodOverloadTo(w, name, wrapper, name_prefix)
        }
    }
    
    FindTypeDefByName(name) {
        ComCall(9, this, "wstr", name, "uint", 0, "uint*", &r:=0)
        return r
    }
    
    GetTypeDefProps(td, &flags:=0, &basetd:=0) {
        namebuf := Buffer(2*MetaDataModule.MAX_NAME_CCH)
        ; GetTypeDefProps
        ComCall(12, this, "uint", td
            , "ptr", namebuf, "uint", namebuf.Size//2, "uint*", &namelen:=0
            , "uint*", &flags:=0, "uint*", &basetd:=0)
        ; Testing shows namelen includes a null terminator, but the docs aren't
        ; clear, so rely on StrGet's positive-length behaviour to truncate.
        return StrGet(namebuf, namelen, "UTF-16")
    }
    
    GetTypeRefProps(r, &scope:=unset) {
        namebuf := Buffer(2*MetaDataModule.MAX_NAME_CCH)
        ComCall(14, this, "uint", r, "uint*", &scope:=0
            , "ptr", namebuf, "uint", namebuf.size//2, "uint*", &namelen:=0)
        return StrGet(namebuf, namelen, "UTF-16")
    }
    
    GetGuidPtr(td) {
        ; GetCustomAttributeByName
        if ComCall(60, this, "uint", td
            , "wstr", "Windows.Foundation.Metadata.GuidAttribute"
            , "ptr*", &pguid:=0, "uint*", &nguid:=0) != 0
            return 0
        ; Attribute is serialized with leading 16-bit version (1) and trailing 16-bit number of named args (0).
        if nguid != 20
            throw Error("Unexpected GuidAttribute data length: " nguid)
        return pguid + 2
    }
    
    EnumMethods(td)                 => _rt_Enumerator(18, this, "uint", td)
    EnumCustomAttributes(td, tctor) => _rt_Enumerator(53, this, "uint", td, "uint", tctor)
    EnumTypeDefs()                  => _rt_Enumerator(6, this)
    EnumInterfaceImpls(td)          => _rt_Enumerator(7, this, "uint", td)
    
    Name {
        get {
            namebuf := Buffer(2*MetaDataModule.MAX_NAME_CCH)
            ; GetScopeProps
            ComCall(10, this, "ptr", namebuf, "uint", namebuf.Size//2, "uint*", &namelen:=0, "ptr", 0)
            return StrGet(namebuf, namelen, "UTF-16")
        }
    }
    
    static Open(path) {
        static CLSID_CorMetaDataDispenser := GUID("{E5CB7A31-7512-11d2-89CE-0080C792E5D8}")
        static IID_IMetaDataDispenser := GUID("{809C652E-7396-11D2-9771-00A0C9B4D50C}")
        static IID_IMetaDataImport := GUID("{7DAC8207-D3AE-4C75-9B67-92801A497D44}")
        #DllLoad rometadata.dll
        DllCall("rometadata.dll\MetaDataGetDispenser"
            , "ptr", CLSID_CorMetaDataDispenser, "ptr", IID_IMetaDataDispenser
            , "ptr*", mdd := ComValue(13, 0), "hresult")
        ; IMetaDataDispenser::OpenScope
        ComCall(4, mdd, "wstr", path, "uint", 0
            , "ptr", IID_IMetaDataImport
            , "ptr*", mdm := this())
        return mdm
    }
}

class RtTypeInfo
{
    __new(mdm, token, typeArgs := false)
    {
        this.m := mdm
        this.t := token
        this.typeArgs := typeArgs

        ; Determine the base type and corresponding RtTypeInfo subclass.
        mdm.GetTypeDefProps(token, &flags, &tbase)
        this.IsSealed := flags & 0x100 ; tdSealed (not composable; can't be subclassed)
        switch
        {
        case flags & 0x20:
            this.base := RtTypeInfo.Interface.Prototype
        case (tbase & 0x00ffffff) = 0:  ; Nil token.
            throw Error(Format('Type "{}" has no base type or interface flag (flags = 0x{:x})', this.Name, flags))
        default:
            basetype := this.m.GetTypeByToken(tbase)
            if basetype is RtTypeInfo
                this.base := basetype.base
            else if basetype.hasProp('TypeClass')
                this.base := basetype.TypeClass.Prototype
            ;else: just leave RtTypeInfo as base.
            this.SuperType := basetype
        }
    }

    class Interface extends RtTypeInfo
    {
        Class => this.m.CreateInterfaceWrapper(this)
        ArgPassInfo => RtInterfaceArgPassInfo(this)
        ReadWriteInfo => RtInterfaceReadWriteInfo(this)
    }

    class Object extends RtTypeInfo
    {
        Class => this.m.CreateClassWrapper(this)
        ArgPassInfo => RtObjectArgPassInfo(this)
        ReadWriteInfo => RtInterfaceReadWriteInfo(this)
    }

    class Struct extends RtTypeInfo
    {
        Class => _rt_CreateStructWrapper(this)
        Size => this.Class.Prototype.Size
        ReadWriteInfo => ReadWriteInfo.FromClass(this.Class)
    }

    class Enum extends RtTypeInfo
    {
        Class => _rt_CreateEnumWrapper(this)
        ArgPassInfo => RtEnumArgPassInfo(this)
    }

    class Delegate extends RtTypeInfo
    {
        ArgPassInfo => RtDelegateArgPassInfo(this)
    }

    class Attribute extends RtTypeInfo
    {
        ; Just for identification. Attributes are only used in metadata.
    }

    ArgPassInfo => false
    ReadWriteInfo => false

    Name => this.ToString()

    ToString()
    {
        name := this.m.GetTypeDefProps(this.t)
        if this.typeArgs
        {
            for t in this.typeArgs
                name .= (A_Index = 1 ? '<' : ',') . String(t)
            name .= '>'
        }
        return name
    }

    GUID => _rt_memoize(this, 'GUID')
    _init_GUID() => this.typeArgs
        ? _rt_GetParameterizedIID(this.m.GetTypeDefProps(this.t), this.typeArgs)
            : this.m.GetGuidPtr(this.t)

    ; Whether this class type supports direct activation (IActivationFactory).
    HasIActivationFactory => _rt_Enumerator(53, this.m, "uint", this.t, "uint", this.m.ActivatableAttr)(&_)
    ; Enumerate factory interfaces of this class type.
    Factories() => _rt_EnumAttrWithTypeArg(this.m, this.t, this.m.FactoryAttr)
    ; Enumerate composition factory interfaces of this class type.
    Composers() => _rt_EnumAttrWithTypeArg(this.m, this.t, this.m.ComposableAttr)
    ; Enumerate static member interfaces of this class type.
    Statics() => _rt_EnumAttrWithTypeArg(this.m, this.t, this.m.StaticAttr)

    ; Enumerate fields of this struct/enum type.
    Fields()
    {
        namebuf := Buffer(2 * MetaDataModule.MAX_NAME_CCH)
        getinfo(&f)
        {
            ; GetFieldProps
            ComCall(57, this.m, "uint", ft := f, "ptr", 0
                , "ptr", namebuf, "uint", namebuf.size // 2, "uint*", &namelen := 0
                , "ptr*", &flags := 0, "ptr*", &psig := 0, "uint*", &nsig := 0
                , "ptr", 0, "ptr", 0, "ptr", 0)
            f := {
                flags: flags,
                name: StrGet(namebuf, namelen, "UTF-16"),
                ; Signature should be CALLCONV_FIELD (6) followed by a single type.
                type: _rt_DecodeSigType(this.m, &p := psig + 1, psig + nsig, this.typeArgs),
            }
            if flags & 0x8000 ; fdHasDefault
                f.value := _rt_GetFieldConstant(this.m, ft)
        }
        ; EnumFields
        return _rt_Enumerator_f(getinfo, 20, this.m, "uint", this.t)
    }

    ; Enumerate methods of this interface/class type.
    Methods()
    {
        namebuf := Buffer(2 * MetaDataModule.MAX_NAME_CCH)
        resolve_method(&m)
        {
            ; GetMethodProps
            ComCall(30, this.m, "uint", m, "ptr", 0
                , "ptr", namebuf, "uint", namebuf.size // 2, "uint*", &namelen := 0
                , "uint*", &attr := 0
                , "ptr*", &psig := 0, "uint*", &nsig := 0 ; signature blob
                , "ptr", 0, "ptr", 0)
            m := {
                name: StrGet(namebuf, namelen, "UTF-16"),
                flags: attr, ; CorMethodAttr
                sig: { ptr: psig, size: nsig },
                t: m
            }
        }
        return _rt_Enumerator_f(resolve_method, 18, this.m, "uint", this.t)
    }

    ; Decode a method signature and return [return type, parameter types*].
    MethodArgTypes(sig)
    {
        if (NumGet(sig, 0, "uchar") & 0x0f) > 5
            throw ValueError("Invalid method signature", -1)
        return _rt_DecodeSig(this.m, sig.ptr, sig.size, this.typeArgs)
    }

    MethodArgProps(method)
    {
        args := []
        ; GetParamForMethodIndex
        ComCall(52, this.m, "uint", method.t, "uint", 1, "uint*", &pd := 0)
        namebuf := Buffer(2 * MetaDataModule.MAX_NAME_CCH)
        loop NumGet(method.sig, 1, "uchar")
        { ; Get arg count from signature.
            ; GetParamProps
            ComCall(59, this.m, "uint", pd + A_Index - 1
                , "ptr*", &md := 0, "uint*", &index := 0
                , "ptr", namebuf, "uint", namebuf.size // 2, "uint*", &namelen := 0
                , "uint*", &attr := 0, "ptr", 0, "ptr", 0, "ptr", 0)
            if md != method.t || index != A_Index
                throw Error('Unexpected ParamDef sequence in metadata')
            args.Push {
                flags: attr,
                name: StrGet(namebuf, namelen, "UTF-16"),
            }
        }
        return args
    }

    Implements()
    {
        ; EnumInterfaceImpls
        next_inner := _rt_Enumerator(7, this.m, "uint", this.t)
        next_outer(&typeinfo, &impltoken := unset)
        {
            if !next_inner(&impltoken)
                return false
            ; GetInterfaceImplProps
            ComCall(13, this.m, "uint", impltoken, "ptr", 0, "uint*", &t := 0)
            typeinfo := this.m.GetTypeByToken(t, this.typeArgs)
            return true
        }
        return next_outer
    }
}

class RtDecodedType
{
    FundamentalType => this
}

class RtTypeArg extends RtDecodedType
{
    __new(n)
    {
        this.index := n
    }
    ToString() => "T" this.index
}

class RtTypeMod extends RtDecodedType
{
    __new(inner)
    {
        this.inner := inner
    }
}

class RtPtrType extends RtTypeMod
{
    ArgPassInfo => ArgPassInfo.Unsupported
    ToString() => String(this.inner) "*"
}

class RefObjPtrAdapter
{
    __new(stn, nts, r)
    {
        this.r := r
        this.stn := stn
        this.nts := nts
    }
    ptr
    {
        get
        {
            if !IsSetRef(this.r)
                return 0
            v := this.stn ? (this.stn)(%this.r%) : %this.r%
            ; v is stored in this.v to keep it alive until after ComCall's caller releases the parameters (including 'this').
            return v is Integer ? v : (this.v := v).Ptr
        }
        set => %this.r% := (this.nts)(value)
    }
}

class RtRefType extends RtTypeMod
{
    ; TODO: check in/out-ness instead of IsSet
    __new(inner)
    {
        super.__new(inner)
        if api := inner.ArgPassInfo
        {
            numberRef_ScriptToNative(&v) => isSet(v) ? &v : &v := 0
            refPtrType_ScriptToNative(a, v) => v = 0 && v is Integer ? v : a(v)
            canTreatAsPtr(nt)
            {
                return nt != 'float' && nt != 'double' && (A_PtrSize = 8 || !InStr(nt, '64'))
            }
            if api.NativeToScript && canTreatAsPtr(api.NativeType)
            {
                this.ArgPassInfo := ArgPassInfo(
                    'Ptr*',
                    refPtrType_ScriptToNative.Bind(ObjBindMethod(RefObjPtrAdapter, , api.ScriptToNative, api.NativeToScript)),
                    false
                )
                return
            }
            else if !(api.ScriptToNative || api.NativeToScript)
            {
                this.ArgPassInfo := ArgPassInfo(
                    api.NativeType '*',
                    numberRef_ScriptToNative,
                    false
                )
                return
            }
            MsgBox 'DEBUG: RtRefType being constructed for type "' String(inner) '", with unsupported ArgPassInfo properties'
        }
        else if !(inner is RtTypeInfo.Struct) && inner != RtRootTypes.Guid
        {
            MsgBox 'DEBUG: RtRefType being constructed for type "' String(inner) '", which has no ArgPassInfo'
        }
        ; TODO: perform type checking in ScriptToNative
        this.ArgPassInfo := FFITypes.IntPtr.ArgPassInfo
    }
    ScriptToNative => (&v) => isSet(v) ? &v : &v := 0
    NativeType => this.inner.NativeType '*'
    ToString() => String(this.inner) "&"
}

class RtArrayType extends RtTypeMod
{
    ArgPassInfo => ArgPassInfo.Unsupported
    ToString() => String(this.inner) "[]"
}
class RtAny
{
    static __new()
    {
        if this = RtAny ; Subclasses will inherit it anyway.
            this.DefineProp('__set', { call: this.prototype.__set })
    }
    static Call(*)
    {
        throw Error("This class is abstract and cannot be constructed.", -1, this.prototype.__class)
    }
    __set(name, *)
    {
        throw PropertyError(Format('This value of type "{}" has no property named "{}".', type(this), name), -1)
    }
}

class RtObject extends RtAny
{
    static __new()
    {
        this.DefineProp('ptr', { value: 0 })
        this.prototype.DefineProp('ptr', { value: 0 })
        this.DefineProp('__delete', { call: this.prototype.__delete })
    }
    __delete()
    {
        (this.ptr) && ObjRelease(this.ptr)
    }
}

_rt_Enumerator(args*) => _rt_Enumerator_f(false, args*)

_rt_Enumerator_f(f, methodidx, this, args*) {
    henum := index := count := 0
    ; Getting the items in batches improves performance, with diminishing returns.
    buf := Buffer(4 * batch_size:=32)
    ; Prepare the args for ComCall, with the caller's extra args in the middle.
    args.InsertAt(1, methodidx, this, "ptr*", &henum)
    args.Push("ptr", buf, "uint", batch_size, "uint*", &count)
    ; Call CloseEnum when finished enumerating.
    args.__delete := args => ComCall(3, this, "uint", henum, "int")
    next(&item) {
        if index = count {
            index := 0
            if ComCall(args*) ; S_FALSE (1) means no items.
                return false
        }
        item := NumGet(buf, (index++) * 4, "uint")
        (f) && f(&item)
        return true
    }
    return next
}

_rt_FindAssemblyRef(mdai, target_name) {
    namebuf := Buffer(2*MetaDataModule.MAX_NAME_CCH)
    ; EnumAssemblyRefs
    for asm in _rt_Enumerator(8, mdai) {
        ; GetAssemblyRefProps
        ComCall(4, mdai , "uint", asm, "ptr", 0, "ptr", 0
            , "ptr", namebuf, "uint", namebuf.Size//2, "uint*", &namelen:=0
            , "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0)
        if StrGet(namebuf, namelen, "UTF-16") = target_name
            return asm
    }
    return 0
}

_rt_CacheAttributeCtors(mdi, o, retprop) {
    mdai := ComObjQuery(mdi, "{EE62470B-E94B-424e-9B7C-2F00C9249F93}") ; IID_IMetaDataAssemblyImport
    ; Currently we assume if there's no reference to Windows.Foundation,
    ; the current scope of mdi (mdModule(1)) is Windows.Foundation.
    asm := _rt_FindAssemblyRef(mdai, "Windows.Foundation") || 1
    
    defOnce(o, n, v) {
        if o.HasOwnProp(n)  ; We currently only support one constructor overload for each usage.
            && o.%n% != v
            throw Error("Conflicting constructor found for " n, -1)
        o.DefineProp n, {value: v}
    }
    
    searchFor(attrType, nameForSig) {
        ; FindTypeRef
        if ComCall(55, mdi, "uint", asm, "wstr", attrType, "uint*", &tr:=0, "int") != 0 {
            defOnce(o, nameForSig(0), -1)
            return
        }
        ; EnumMemberRefs
        for mr in _rt_Enumerator(23, mdi, "uint", tr) {
            ; GetMemberRefProps
            ComCall(31, mdi, "uint", mr, "uint*", &ttype:=0
                , "ptr", 0, "uint", 0, "ptr", 0
                , "ptr*", &psig:=0, "uint*", &nsig:=0)
            defOnce(o, nameForSig(psig), mr)
        }
        else {
            ; This module doesn't contain any references to attrType, so none of
            ; its typedefs use that attribute.  Set -1 (invalid) to avoid reentry.
            defOnce(o, nameForSig(0), -1)
        }
    }
    
    searchFor("Windows.Foundation.Metadata.StaticAttribute"
        , psig => 'StaticAttr')
    
    searchFor("Windows.Foundation.Metadata.ActivatableAttribute"
        , psig => NumGet(psig, 3, "uchar") = 9 ? 'ActivatableAttr' : 'FactoryAttr') ; 9 = uint (first arg is uint, not interface name)
    
    searchFor("Windows.Foundation.Metadata.ComposableAttribute"
        , psig => 'ComposableAttr')
    
    return o.%retprop%
}

_rt_GetFieldConstant(mdi, field) {
    mdt := ComObjQuery(mdi, "{D8F579AB-402D-4B8E-82D9-5D63B1065C68}") ; IMetaDataTables
    
    static tabConstant := 11, GetTableInfo := 9
    ComCall(GetTableInfo, mdt, "uint", tabConstant
        , "ptr", 0, "uint*", &cRows := 0, "ptr", 0, "ptr", 0, "ptr", 0)
    
    static colType := 0, colParent := 1, colValue := 2, GetColumn := 13, GetBlob := 15
    Loop cRows {
        ComCall(GetColumn, mdt, "uint", tabConstant, "uint", colParent, "uint", A_Index, "uint*", &value:=0)
        if value != field
            continue
        ComCall(GetColumn, mdt, "uint", tabConstant, "uint", colValue, "uint", A_Index, "uint*", &value:=0)
        ComCall(GetBlob, mdt, "uint", value, "uint*", &ndata:=0, "ptr*", &pdata:=0)
        ComCall(GetColumn, mdt, "uint", tabConstant, "uint", colType, "uint", A_Index, "uint*", &value:=0)
        ; Type must be one of the basic element types (2..14) or CLASS (18) with value 0.
        ; WinRT only uses constants for enums, always I4 (8) or U4 (9).
        static primitives := _rt_GetElementTypeMap()
        return primitives[value].ReadWriteInfo.GetReader()(pdata)
        ;return {ptr: pdata, size: ndata}
    }
}

_rt_GetElementTypeMap() {
    static etm
    if !IsSet(etm) {
        etm := Map()
        eta := [
            0x1, 'Void',
            0x2, 'Boolean',
            0x3, 'Char16',
            0x4, 'Int8',
            0x5, 'UInt8',
            0x6, 'Int16',
            0x7, 'UInt16',
            0x8, 'Int32',
            0x9, 'UInt32',
            0xa, 'Int64',
            0xb, 'UInt64',
            0xc, 'Single',
            0xd, 'Double',
            0xe, 'String',
            0x18, 'IntPtr',
            0x1c, 'Object',
        ]
        i := 1
        loop eta.length//2 {
            etm[eta[i]] := RtRootTypes.%eta[i+1]%
            i += 2
        }
    }
    return etm
}

MethodWrapper(idx, iid, types, name:=unset) {
    rettype := types.RemoveAt(1)
    cca := [] ;, cca.Length := 1 + 2*types.Length, ccac := 0
    stn := Map()
    if iid
        stn[1] := ComObjQuery.Bind( , iid)
    args_to_expand := Map()
    for t in types {
        if pass := t.ArgPassInfo {
            if pass.ScriptToNative
                stn[1 + A_Index] := pass.ScriptToNative
            cca.Push( , pass.NativeType)
        }
        else {
            if !InStr('Struct|Guid', String(t.FundamentalType))
                MsgBox 'DEBUG: arg type ' String(t) ' of ' name ' is not a struct and has no ArgPassInfo'
            arg_size := t.Size
            if arg_size <= 8 || A_PtrSize = 4 {
                ; On x86, all structs need to be copied by value into the parameter list.
                ; On x64, structs <= 8 bytes need to be copied but larger structs are
                ; passed by value.
                ; Not sure how ARM64 does it.
                args_to_expand[A_Index + 1] := arg_size  ; +1 to account for `this`
                loop ceil(arg_size / A_PtrSize)
                    cca.Push( , 'ptr')
            }
            else {
                ; Large struct to be passed by address.
                cca.Push( , 'ptr')
            }
            ; TODO: check type of incoming parameter value
        }
    }
    if rettype != FFITypes.Void {
        if pass := rettype.ArgPassInfo {
            fri := () => &newvarref := 0
            cca.Push( , pass.NativeType '*')
            frr := ((nts, &ref) => nts(ref)).Bind(pass.NativeToScript || Number)
        }
        else {
            ; Struct?
            if !InStr('Struct|Guid', String(rettype.FundamentalType))
                MsgBox 'DEBUG: return type ' String(rettype) ' of ' name ' is not a struct and has no ArgPassInfo'
            fri := rettype.Class
            cca.Push( , 'ptr')
            frr := false
        }
    }
    else {
        frr := fri := false
    }
    ; Build the core ComCall function with predetermined type parameters.
    fc := ComCall.Bind(idx, cca*)
    if args_to_expand.Count
        fc := _rt_get_struct_expander(args_to_expand, fc)
    ; Define internal properties for use by _rt_call.
    if IsSet(name)
        fc.DefineProp 'Name', {value: name}  ; For our use debugging; has no effect on any built-in stuff.
    fc.DefineProp 'MinParams', pv := {value: 1 + types.Length}  ; +1 for `this`
    fc.DefineProp 'MaxParams', pv
    ; Compose the ComCall and parameter filters into a function.
    fc := _rt_call.Bind(fc, stn, fri, frr)
    ; Define external properties for use by OverloadedFunc and others.
    fc.DefineProp 'MinParams', pv
    fc.DefineProp 'MaxParams', pv
    return fc
}


_rt_get_struct_expander(sizes, fc) {
    ; Map the incoming parameter index and size to outgoing parameter index and size.
    ismap := Map(), offset := 0
    for i, size in sizes {
        ismap[i + offset] := size
        offset += Ceil(size / A_PtrSize) - 1
    }
    return _rt_expand_struct_args.Bind(ismap, fc)
}

_rt_expand_struct_args(ismap, fc, args*) {
    local struct
    for i, size in ismap {
        ; Removing struct from args shouldn't cause its destructor to be called (when this
        ; function returns) because it should still be on the caller's stack.  For simple
        ; structs it doesn't matter either way, because their values are copied here.
        struct := args.RemoveAt(i), new_args := []
        ; This specifically allows NumGet to read past the end of the struct when the size
        ; is not a multiple of A_PtrSize, with the additional bytes being "undefined".
        ptr := struct.ptr, endptr := ptr + struct.size
        while ptr < endptr
            new_args.Push(NumGet(ptr, 'ptr')), ptr += A_PtrSize
        args.InsertAt(i, new_args*)
    }
    return fc(args*)
}

_rt_rethrow(fc, e) {
    e.Stack := RegExReplace(e.Stack, 'mS)^\Q' StrReplace(A_LineFile, '\E', '\E\\E\Q') '\E \(\d+\) :.*\R',, &count)
    if count && RegExMatch(e.Stack, 'S)^(?<File>.*) \((?<Line>\d+)\) :', &m) {
        e.Stack := StrReplace(e.Stack, '[Func.Prototype.Call]', '[' fc.Name ']')
        e.File := m.File, e.Line := m.Line
    }
    throw
}

_rt_call(fc, fa, fri, frr, args*) {
    try {
        if args.Length != fc.MinParams
            throw Error(Format('Too {} parameters passed to function {}.', args.Length < fc.MinParams ? 'few' : 'many', fc.Name), -1)
        for i, f in fa
            args[i] := f(args[i])
        (fri) && args.Push(fri())
        fc(args*)
        return frr ? frr(args.Pop()) : fri ? args.Pop() : ""
    } catch OSError as e {
        _rt_rethrow(fc, e)
    }
}




_rt_CreateClass(classname, baseclass) {
    w := Class()
    w.base := baseclass
    w.prototype := {__class: classname, base: baseclass.prototype}
    return w
}

_rt_CreateStructWrapper(t) {
    local fd
    w := _rt_CreateClass(t.Name, ValueType)
    t.DefineProp 'Class', {value: w}
    wp := w.prototype
    offset := 0, alignment := 1
    readwriters := Map(), destructors := []
    for f in t.Fields() {
        ft := f.type
        rwi := ReadWriteInfo.ForType(ft)
        fsize := rwi.Size
        falign := rwi.HasProp('Align') ? rwi.Align : fsize
        offset := align(offset, fsize)
        wp.DefineProp f.name, {
            get: reader := rwi.GetReader(offset),
            set: writer := rwi.GetWriter(offset)
        }
        readwriters[reader] := writer
        if fd := rwi.GetDeleter(offset)
            destructors.Push(fd)
        if alignment < falign
            alignment := falign
        offset += fsize
    }
    align(n, to) => (n + (to - 1)) // to * to
    w.DefineProp 'Align', {value: alignment}
    wp.DefineProp 'Size', {value: align(offset, alignment)}
    if destructors.Length {
        struct_delete(destructors, this) {
            if this.HasProp('_outer_') ; Lifetime managed by outer RtStruct.
                return
            for d in destructors
                try
                    d(this)
                catch as e ; Ensure all destructors are called ...
                    thrown := e
            if IsSet(thrown)
                throw thrown ; ... and the last error is reported.
        }
        struct_copy(readwriters, this, ptr) {
            for reader, writer in readwriters
                writer(ptr, reader(this))
        }
        wp.DefineProp 'CopyToPtr', {call: struct_copy.Bind(readwriters)}
        wp.DefineProp '__delete', {call: struct_delete.Bind(destructors)}
    }
    return w
}

_rt_stringPointerArray(strings) {
    chars := 0
    for s in strings
        chars += StrLen(s) + 1
    b := Buffer((strings.Length * A_PtrSize) + (chars * 2))
    p := b.ptr + strings.Length * A_PtrSize
    for s in strings {
        NumPut('ptr', p, b, (A_Index - 1) * A_PtrSize)
        p += StrPut(s, p)
    }
    return b
}

_rt_GetParameterizedIID(name, types) {
    static vt := Buffer(A_PtrSize)
    static pvt := NumPut("ptr", CallbackCreate(_rt_MetaDataLocate, "F"), vt) - A_PtrSize
    ; Make an array of pointers to the names.  StrPtr(names[1]) would return
    ; the address of a temporary string, so make more direct copies.
    names := [name]
    makeNames(types)
    makeNames(types) {
        for t in types {
            if t.HasProp('typeArgs') && t.typeArgs {
                ; Need the individual names of base type and each type arg.
                names.Push(t.m.GetTypeDefProps(t.t))
                makeNames(t.typeArgs)
            }
            else {
                names.Push(String(t))
            }
        }
    }
    namePtrArr := _rt_stringPointerArray(names)
    hr := DllCall("combase.dll\RoGetParameterizedTypeInstanceIID"
        , "uint", names.Length, "ptr", namePtrArr
        , "ptr*", pvt  ; "*" turns it into an "object" on DllCall's stack.
        , "ptr", oiid := GUID(), "ptr*", &pextra:=0, "hresult")
    DllCall("combase.dll\RoFreeParameterizedTypeExtra"
        , "ptr", pextra)
    return oiid
}

_rt_MetaDataLocate(this, pname, mdb) {
    name := StrGet(pname, "UTF-16")
    ; mdb : IRoSimpleMetaDataBuilder -- unconventional interface with no base type
    try {
        t := WinRT.GetType(name)
        switch String(t.FundamentalType) {
        case "Interface":
            if !(pguid := t.GUID)
                throw Error("GUID not found for " name)
            if p := InStr(name, "``") {
                ; SetParameterizedInterface
                if A_PtrSize = 8 ; x64
                    ComCall(8, mdb, "ptr", pguid, "uint", SubStr(name, p + 1))
                else
                    ComCall(8, mdb, "int64", NumGet(pguid, "int64"), "int64", NumGet(pguid + 8, "int64"), "uint", SubStr(name, p + 1))
            }
            else {
                ; SetWinRtInterface
                if A_PtrSize = 8 ; x64
                    ComCall(0, mdb, "ptr", pguid)
                else
                    ComCall(0, mdb, "int64", NumGet(pguid, "int64"), "int64", NumGet(pguid + 8, "int64"))
            }
        case "Object":
            t := WinRT.GetType(name).Class.__DefaultInterface
            ; SetRuntimeClassSimpleDefault
            ComCall(4, mdb, "ptr", pname, "wstr", t.Name, "ptr", t.GUID)
        case "Delegate":
            if !(pguid := t.GUID)
                throw Error("GUID not found for " name)
            if p := InStr(name, "``") {
                ; SetParameterizedDelete
                if A_PtrSize = 8 ; x64
                    ComCall(9, mdb, "ptr", pguid, "uint", SubStr(name, p + 1))
                else
                    ComCall(9, mdb, "int64", NumGet(pguid, "int64"), "int64", NumGet(pguid + 8, "int64"), "uint", SubStr(name, p + 1))
            }
            else {
                ; SetDelegate
                if A_PtrSize = 8 ; x64
                    ComCall(1, mdb, "ptr", pguid)
                else
                    ComCall(1, mdb, "int64", NumGet(pguid, "int64"), "int64", NumGet(pguid + 8, "int64"))
            }
        case "Struct":
            names := []
            for field in t.Fields()
                names.Push(String(field.type))
            namePtrArr := _rt_stringPointerArray(names)
            ; SetStruct
            ComCall(6, mdb, "ptr", pname, "uint", names.Length, "ptr", namePtrArr)
        case "Enum":
            ; SetEnum
            ComCall(7, mdb, "ptr", pname, "wstr", t.Class.__basicType.Name)
        default:
            throw Error('Unsupported fundamental type')
        }
    }
    catch as e {
        ; @Debug-Output => {e.__class} locating metadata for {name}: {e.message}
        ; @Debug-Breakpoint
        return 0x80004005 ; E_FAIL
    }
    return 0
}








_rt_EnumAttrWithTypeArg(mdi, t, attr) {
    attrToType(&v) {
        ; GetCustomAttributeProps
        ComCall(54, mdi, "uint", v
            , "ptr", 0, "ptr", 0, "ptr*", &pdata:=0, "uint*", &ndata:=0)
        v := WinRT.GetType(getArg1String(pdata))
    }
    getArg1String(pdata) {
        return StrGet(pdata + 3, NumGet(pdata + 2, "uchar"), "utf-8")
    }
    ; EnumCustomAttributes := 53
    return _rt_Enumerator_f(attrToType, 53, mdi, "uint", t, "uint", attr)
}

_rt_DecodeSig(m, p, size, typeArgs:=false) {
    if size < 3
        throw Error("Invalid signature")
    p2 := p + size
    cconv := NumGet(p++, "uchar")
    argc := NumGet(p++, "uchar") + 1 ; +1 for return type
    return _rt_DecodeSigTypes(m, &p, p2, argc, typeArgs)
}

_rt_DecodeSigTypes(m, &p, p2, count, typeArgs:=false) {
    if p > p2
        throw ValueError("Bad params", -1)
    types := []
    while p < p2 && count {
        types.Push(_rt_DecodeSigType(m, &p, p2, typeArgs))
        --count
    }
    ; > vs != is less robust, but some callers want a subset of a signature.
    if p > p2
        throw Error("Signature decoding error")
    return types
}

_rt_DecodeSigGenericInst(m, &p, p2, typeArgs:=false) {
    if p > p2
        throw ValueError("Bad params", -1)
    baseType := _rt_DecodeSigType(m, &p, p2, typeArgs)
    types := []
    types.Capacity := count := NumGet(p++, "uchar")
    while p < p2 && count {
        types.Push(_rt_DecodeSigType(m, &p, p2, typeArgs))
        --count
    }
    if p > p2
        throw Error("Signature decoding error")
    t := {
        typeArgs: types,
        m: baseType.m, t: baseType.t,
        base: baseType.base
        ; base: baseType -- not doing this because most of the cached properties
        ; need to be recalculated for the generic instance, GUID in particular.
    }
    ; Check/update cache to ensure there's only one typeinfo for this combination of
    ; types (to reduce memory usage and permit other optimizations).  This could be
    ; optimized by decoding sig to names only, rather than resolving to the array
    ; of types (above).
    if cached := WinRT.TypeCache.Get(tname := t.Name, false)
        return cached
    return WinRT.TypeCache[tname] := t
}

_rt_DecodeSigType(m, &p, p2, typeArgs:=false) {
    static primitives := _rt_GetElementTypeMap()
    static modifiers := Map(
        0x0f, RtPtrType,
        0x10, RtRefType,
        0x1D, RtArrayType,
    )
    b := NumGet(p++, "uchar")
    if t := primitives.get(b, 0)
        return t
    if modt := modifiers.get(b, 0)
        return modt(_rt_DecodeSigType(m, &p, p2, typeArgs))
    switch b {
        case 0x11, 0x12: ; value type, class type
            return m.GetTypeByToken(CorSigUncompressToken(&p))
        case 0x13: ; generic type parameter
            if typeArgs
                return typeArgs[NumGet(p++, "uchar") + 1]
            return RtTypeArg(NumGet(p++, "uchar") + 1)
        case 0x15: ; GENERICINST <generic type> <argCnt> <arg1> ... <argn>
            return _rt_DecodeSigGenericInst(m, &p, p2, typeArgs)
        case 0x1F, 0x20: ; CMOD <typeDef/Ref> ...
            modt := CorSigUncompressToken(&p) ; Must be called to advance the pointer.
            ; modt := m.GetTypeRefProps(modt)
            t := _rt_DecodeSigType(m, &p, p2, typeArgs)
            ; So far I've only observed modt='System.Runtime.CompilerServices.IsConst'
            ; @Debug-Breakpoint(modt !~ 'IsConst') => Unhandled modifier {modt} on type {t.__class}{t}
            return t
    }
    throw Error("type not handled",, Format("{:02x}", b))
}

CorSigUncompressedDataSize(p) => (
    (NumGet(p, "uchar") & 0x80) = 0x00 ? 1 :
    (NumGet(p, "uchar") & 0xC0) = 0x80 ? 2 : 4
)
CorSigUncompressData(&p) {
    if (NumGet(p, "uchar") & 0x80) = 0x00
        return  NumGet(p++, "uchar")
    if (NumGet(p, "uchar") & 0xC0) = 0x80
        return (NumGet(p++, "uchar") & 0x3f) << 8
            |   NumGet(p++, "uchar")
    else
        return (NumGet(p++, "uchar") & 0x1f) << 24
            |   NumGet(p++, "uchar") << 16
            |   NumGet(p++, "uchar") << 8
            |   NumGet(p++, "uchar")
}
CorSigUncompressToken(&p) {
    tk := CorSigUncompressData(&p)
    return [0x02000000, 0x01000000, 0x1b000000, 0x72000000][(tk & 3) + 1]
        | (tk >> 2)
}



/*
CreateTypedCallback(fn, opt, argTypes) {
    local readers := GetReadersForArgTypes(argTypes)
    typed_callback(argPtr) {
        args := []
        for r in readers {
            args.Push(r(argPtr))
        }
        return fn(args*)
    }
    return CallbackCreate(typed_callback, opt "&", readers.NativeSize // A_PtrSize)
}
*/

GetReadersForArgTypes(argTypes) {
    readers := [], offset := 0
    for argType in argTypes {
        rwi := ReadWriteInfo.ForType(argType)
        if rwi.Size > 8 && 8 = A_PtrSize {
            ; Structs larger than 8 bytes are passed by address on x64.
            deref_and_read(r, o, p) => r(NumGet(p, o, "ptr"))
            reader := deref_and_read.Bind(rwi.GetReader(0), offset)
            offset += A_PtrSize
        }
        else {
            reader := rwi.GetReader(offset)
            offset += A_PtrSize = 4 ? (rwi.Size + 3) // 4 * 4 : A_PtrSize
        }
        readers.Push(reader)
    }
    readers.NativeSize := offset
    return readers
}

class DelegateFactory {
    __new(iid, argTypes, retType:=false) {
        cb := CreateComMethodCallback('Call', argTypes, retType)
        this.mtbl := CreateComMethodTable([cb], iid)
    }
    Call(fn) {
        delegate := DllCall("msvcrt\malloc", "ptr", A_PtrSize * 3, "cdecl ptr")
        NumPut(
            "ptr", this.mtbl.ptr,       ; method table
            "ptr", 1,                   ; ref count
            "ptr", ObjPtrAddRef(fn),    ; target function
            delegate)
        return ComValue(13, delegate)
    }
}



class ValueType extends RtAny {
    static Call() {
        proto := this.Prototype
        b := Buffer(proto.Size, 0)
        return {ptr: b.ptr, _buf_: b, base: proto}
    }
    ; static FromPtr(ptr) {
    ;     return {ptr: ptr, base: this.Prototype}
    ; }
    static FromOffset(buf, offset) {
        return {ptr: buf.ptr + offset, _outer_: buf, base: this.Prototype}
    }
    CopyToPtr(ptr) {
        DllCall('msvcrt\memcpy', 'ptr', ptr, 'ptr', this, 'ptr', this.Size, 'cdecl')
    }
}

class EnumValue extends RtAny {
    static Call(n) {
        if e := this.__item.get(n, 0)
            return e
        return {n: n, base: this.prototype}
    }
    static Parse(v) { ; TODO: parse space-delimited strings for flag enums
        if v is this
            return v.n
        if v is Integer
            return v ; this[v].n would only permit explicitly defined values, but Parse is currently used for all enum args, so this isn't suitable for flag enums.
        if v is String
            return this.%v%.n
        throw TypeError(Format('Value of type "{}" cannot be converted to {}.', type(v), this.prototype.__class), -1)
    }
    s => String(this.n) ; TODO: produce space-delimited strings for flag enums
    ToString() => this.s
}

_rt_CreateEnumWrapper(t) {
    w := _rt_CreateClass(t.Name, EnumValue)
    t.DefineProp 'Class', {value: w}
    def(n, v) => w.DefineProp(n, {value: v})
    def '__item', items := Map()
    for f in t.Fields() {
        switch f.flags {
            case 0x601: ; Private | SpecialName | RTSpecialName
                def '__basicType', f.type
            case 0x8056: ; public | static | literal | hasdefault
                def f.name, items[f.value] := {n: f.value, s: f.name, base: w.prototype}
        }
    }
    return w
}


/*
  Core WinRT functions.
    - WinRT(classname) creates a runtime object.
    - WinRT(rtobj) "casts" rtobj to its most derived class.
    - WinRT(ptr) wraps a runtime interface pointer, taking ownership of the reference.
    - WinRT.GetType(name) returns a TypeInfo for the given type.
*/
class WinRT {
    static Call(p) => (
        p is String ? this.GetType(p).Class :
        p is Object ? (ObjAddRef(p.ptr), _rt_WrapInspectable(p.ptr)) :
        _rt_WrapInspectable(p)
    )
    
    static TypeCache := Map(
        "Guid", RtRootTypes.Guid,  ; Found in type names returned by GetRuntimeClassName.
        "System.Guid", RtRootTypes.Guid,  ; Resolved from metadata TypeRef.
        ; All WinRT typedefs tested on Windows 10.0.19043 derive from one of these.
        'System.Attribute', RtRootTypes.Attribute,
        'System.Enum', RtRootTypes.Enum,
        'System.MulticastDelegate', RtRootTypes.Delegate,
        'System.Object', RtRootTypes.Object,
        'System.ValueType', RtRootTypes.Struct,
    )
    static __new() {
        cache := this.TypeCache
        for e, t in _rt_GetElementTypeMap() {
            ; Map the simple types in cache, for parsing generic type names.
            cache[t.Name] := t
        }
        this.DefineProp('__set', {call: RtAny.__set})
    }
    
    static _CacheGetMetaData(typename, &td) {
        local mn
        #DllLoad wintypes.dll
        DllCall("wintypes.dll\RoGetMetaDataFile"
            , "ptr", HStringFromString(typename)
            , "ptr", 0
            , "ptr", 0
            , "ptr*", m := RtMetaDataModule()
            , "uint*", &td := 0
            , "hresult")
        static cache := Map()
        ; Cache modules by filename to conserve memory and so cached property values
        ; can be used by all namespaces within the module.
        return cache.get(mn := m.Name, false) || cache[mn] := m
    }
    
    static _CacheGetTypeNS(name) {
        if !(p := InStr(name, ".",, -1))
            throw ValueError("Invalid typename", -1, name)
        static cache := Map()
        ; Cache module by namespace, since all types *directly* within a namespace
        ; must be defined within the same file (but child namespaces can be defined
        ; in a different file).
        try {
            if m := cache.get(ns := SubStr(name, 1, p-1), false) {
                ; Module already loaded - find the TypeDef within it.
                td := m.FindTypeDefByName(name)
            }
            else {
                ; Since we haven't seen this namespace before, let the system work out
                ; which module contains its metadata.
                cache[ns] := m := this._CacheGetMetaData(name, &td)
            }
        }
        catch OSError as e {
            if e.number = 0x80073D54 {
                e.message := "(0x80073D54) Type not found."
                e.extra := name
            }
            throw
        }
        return RtTypeInfo(m, td)
    }
    
    static _CacheGetType(name) {
        if p := InStr(name, "<") {
            baseType := this.GetType(baseName := SubStr(name, 1, p-1))
            typeArgs := []
            while RegExMatch(name, "S)\G([^<>,]++(?:<(?:(?1)(?:,|(?=>)))++>)?)(?=[,>])", &m, ++p) {
                typeArgs.Push(this.GetType(m.0))
                p += m.Len
            }
            if p != StrLen(name) + 1
                throw Error("Parse error or bad name.", -1, SubStr(name, p) || name)
            return {
                typeArgs: typeArgs,
                m: baseType.m, t: baseType.t,
                base: baseType.base
            }
        }
        return this._CacheGetTypeNS(name)
    }
    
    static GetType(name) {
        static cache := this.TypeCache
        ; Cache typeinfo by full name.
        return cache.get(name, false)
            || cache[name] := this._CacheGetType(name)
    }
}

class RtMetaDataModule extends MetaDataModule {
    GetTypeByToken(t, typeArgs:=false) {
        scope := -1
        switch (t >> 24) {
        case 0x01: ; TypeRef (most common)
            ; TODO: take advantage of GetTypeRefProps's scope parameter
            return WinRT.GetType(this.GetTypeRefProps(t))
        case 0x02: ; TypeDef
            MsgBox 'DEBUG: GetTypeByToken was called with a TypeDef token.`n`n' Error().Stack
            ; TypeDefs usually aren't referenced directly, so just resolve it by
            ; name to ensure caching works correctly.  Although GetType resolving
            ; the TypeDef will be a bit redundant, it should perform the same as
            ; if a TypeRef token was passed in.
            return WinRT.GetType(this.GetTypeDefProps(t))
        case 0x1b: ; TypeSpec
            ; GetTypeSpecFromToken
            ComCall(44, this, "uint", t, "ptr*", &psig:=0, "uint*", &nsig:=0)
            ; Signature: 0x15 0x12 <typeref> <argcount> <args>
            nsig += psig++
            return _rt_DecodeSigGenericInst(this, &psig, nsig, typeArgs)
        default:
            throw Error(Format("Cannot resolve token 0x{:08x} to type info.", t), -1)
        }
    }
}

_rt_WrapInspectable(p, typeinfo:=false) {
    if !p
        return
    ; IInspectable::GetRuntimeClassName
    hr := ComCall(4, p, "ptr*", &hcls:=0, "int")
    if hr >= 0 {
        cls := HStringRet(hcls)
        if !typeinfo || !InStr(cls, "<")
            typeinfo := WinRT.GetType(cls)
        ; else it's not a full runtime class, so just use the predetermined typeinfo.
    }
    else if !typeinfo || hr != -2147467263 { ; E_NOTIMPL
        e := OSError(hr)
        e.Message := "IInspectable::GetRuntimeClassName failed`n`t" e.Message
        throw e
    }
    return {
        ptr: p,
        base: typeinfo.Class.prototype
    }
}


_rt_memoize(this, propname, f := unset) {
    value := IsSet(f) ? f(this) : this._init_%propname%()
    this.DefineProp propname, {value: value}
    return value
}

CreateComMethodCallback(name, argTypes, retType := false)
{
    readers := GetReadersForArgTypes(argTypes)
    writeRet := retType && retType != FFITypes.Void
        && ReadWriteInfo.ForType(retType).GetWriter(0)
    retOffset := readers.NativeSize
    interface_method(argPtr)
    {
        try
        {
            obj := ObjFromPtrAddRef(NumGet(NumGet(argPtr, 'ptr'), A_PtrSize * 2, 'ptr'))
            argPtr += A_PtrSize
            args := []
            for readArg in readers
                args.Push(readArg(argPtr))
            retval := obj.%name%(args*)
            (writeRet) && writeRet(NumGet(argPtr, retOffset, 'ptr'), retval)
        }
        catch Any as e
        {
            ; @Debug-Breakpoint => {e.__Class} thrown in method {name}: {e.Message}
            return e is OSError ? e.number : 0x80004005
        }
        return 0
    }
    return CallbackCreate(interface_method, "&", retOffset // A_PtrSize + (retType ? 2 : 1))
}

CreateComMethodTable(callbacks, iid)
{
    iunknown_addRef(this)
    {
        ; ++this.refCount
        NumPut("ptr", refCount := NumGet(this, A_PtrSize, "ptr") + 1, this, A_PtrSize)
        return refCount
    }
    iunknown_release(this)
    {
        ; if !--this.refCount
        NumPut("ptr", refCount := NumGet(this, A_PtrSize, "ptr") - 1, this, A_PtrSize)
        if !refCount
        {
            local obj
            ObjRelease(obj := NumGet(this, A_PtrSize * 2, "ptr"))
            DllCall("msvcrt\free", "ptr", this, "cdecl")
        }
        return refCount
    }
    iid := GuidToString(iid)
    iunknown_queryInterface(this, riid, ppvObject)
    {
        riid := GuidToString(riid)
        switch riid
        {
        case iid, "{00000000-0000-0000-C000-000000000046}":
            iunknown_addRef(this)
            NumPut("ptr", this, ppvObject)
            return 0
        }
        NumPut("ptr", 0, ppvObject)
        return 0x80004002
    }

    static p_addRef := CallbackCreate(iunknown_addRef, "F", 1)
    static p_release := CallbackCreate(iunknown_release, "F", 1)
    ; FIXME: for general use, free p_query when mtbl is freed (which never happens for WinRT)
    p_query := CallbackCreate(iunknown_queryInterface, "F", 3)

    mtbl := Buffer((3 + callbacks.Length) * A_PtrSize)
    NumPut("ptr", p_query, "ptr", p_addRef, "ptr", p_release, mtbl)
    for callback in callbacks
    {
        NumPut("ptr", callback, mtbl, (2 + A_Index) * A_PtrSize)
    }
    return mtbl
}

class RtNamespace
{
    static __new()
    {
        this.DefineProp '__set', { call: RtAny.__set }
        this.prototype.DefineProp '__set', { call: RtAny.__set }
    }
    __new(name)
    {
        this.DefineProp '_name', { value: name }
    }
    __call(name, params) => this.__get(name, [])(params*)
    __get(name, params)
    {
        this._populate()
        if this.HasOwnProp(name)
            return params.Length ? this.%name%[params*] : this.%name%
        try
            cls := WinRT(typename := this._name "." name)
        catch OSError as e
        {
            throw (e.number != 0x80073D54 || e.extra != typename) ? e
                : PropertyError("Unknown property, class or namespace", -1, typename)
        }
        this.DefineProp name, { get: this => cls, call: (this, p*) => cls(p*) }
        return params.Length ? cls[params*] : cls
    }
    __enum(n := 1) => (
        this._populate(),
        this.__enum(n)
    )
    _populate()
    {
        ; Subclass should override this and call super._populate().
        enum_ns_props(this, n := 1)
        {
            next_prop := this.OwnProps()
            next_namespace(&name := unset, &value := unset)
            {
                loop
                    if !next_prop(&name, &value)
                        return false
                until value is RtNamespace
                return true
            }
            return next_namespace
        }
        ; Subsequent calls to __enum() should enumerate the populated properties.
        this.DefineProp '__enum', { call: enum_ns_props }
        ; Subsequent calls to _populate() should have no effect.
        this.DefineProp '_populate', { call: IsObject }
        ; Find any direct child namespaces defined in files (for Windows and Windows.UI).
        Loop Files A_WinDir "\System32\WinMetadata\" this._name ".*.winmd", "F"
        {
            name := SubStr(A_LoopFileName, StrLen(this._name) + 2)
            name := SubStr(name, 1, InStr(name, ".") - 1)
            if !this.HasOwnProp(name)
                this.DefineProp name, { value: RtNamespace(this._name "." name) }
        }
        ; Find namespaces in winmd files.
        this._populateFromModule()
    }
    _populateFromModule()
    {
        if this.HasOwnProp('_m')
            return
        this.DefineProp '_m', {
            value: m := RtMetaDataModule.Open(RtNamespace.GetPath(this._name))
        }
        prefix := this._name '.'
        ; Find all namespaces strings in this module.
        static tabTypeDef := 2, colNamespace := 2
        static GetTableInfo := 9, GetColumn := 13, GetString := 14
        mdt := ComObjQuery(m, "{D8F579AB-402D-4B8E-82D9-5D63B1065C68}") ; IMetaDataTables
        ComCall(GetTableInfo, mdt, "uint", tabTypeDef
            , "ptr", 0, "uint*", &cRows := 0, "ptr", 0, "ptr", 0, "ptr", 0)
        ; Find all unique namespace strings referenced by the TypeDef table.
        unique_names := Map()
        Loop cRows
        {
            ComCall(GetColumn, mdt, "uint", tabTypeDef, "uint", colNamespace, "uint", A_Index, "uint*", &index := 0)
            unique_names[index] := 1
        }
        ; For each unique namespace string...
        for index in unique_names
        {
            ComCall(GetString, mdt, "uint", index, "ptr*", &name := 0)
            name := StrGet(name, "UTF-8")
            if SubStr(name, 1, StrLen(prefix)) = prefix
            {
                x := this, len := StrLen(prefix) - 1
                Loop Parse SubStr(name, len + 2), '.'
                {
                    len += 1 + StrLen(A_LoopField)
                    if !x.HasOwnProp(A_LoopField)
                    {
                        ns := RtNamespace(SubStr(name, 1, len))
                        ; Since this namespace hasn't already been discovered as a *.winmd,
                        ; it must only be defined in this module.
                        ns.DefineProp '_m', { value: m }
                        x.DefineProp A_LoopField, { value: ns }
                    }
                    x := x.%A_LoopField%
                }
            }
            ; else it should be either "" or this._name itself.
        }
    }
    static GetPath(name) => A_WinDir "\System32\WinMetadata\" name ".winmd"
}

class Windows
{
    static __new()
    {
        ; Transform this static class into an instance of RtNamespace.
        this._name := "Windows"
        this.DeleteProp 'Prototype'
        this.base := RtNamespace.Prototype
    }
    static __get(name, params)
    {
        if !FileExist(RtNamespace.GetPath(fname := this._name "." name))
            throw Error("Non-existent namespace or missing winmd file.", -1, name)
        this.DefineProp name, { value: n := RtNamespace(fname) }
        return n
    }
    static _populateFromModule() => 0
}
