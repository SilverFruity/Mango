//
//  eval.m
//  MangoFix
//
//  Created by jerry.yong on 2017/12/25.
//  Copyright © 2017年 yongpengliang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <symdl/symdl.h>
#import "mf_ast.h"
#import "ffi.h"
#import "util.h"
#import "mf_ast.h"
#import "execute.h"
#import "create.h"
#import "MFValue+Private.h"
#import "MFVarDeclareChain.h"

static MFValue * execute_expression(MFInterpreter *inter, MFScopeChain *scope, __kindof MFExpression *expr);

static MFValue *invoke_values(id instance, SEL sel, NSArray<MFValue *> *argValues){
    if (!instance) {
        return [MFValue valueInstanceWithInt:0];
    }
    NSMethodSignature *sig = [instance methodSignatureForSelector:sel];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    invocation.target = instance;
    invocation.selector = sel;
    NSUInteger argCount = [sig numberOfArguments];
    for (NSUInteger i = 2; i < argCount; i++) {
        const char *typeEncoding = [sig getArgumentTypeAtIndex:i];
        void *ptr = malloc(mf_size_with_encoding(typeEncoding));
        [argValues[i-2] assignToCValuePointer:ptr typeEncoding:typeEncoding];
        [invocation setArgument:ptr atIndex:i];
        free(ptr);
    }
    [invocation invoke];
    
    char *returnType = (char *)[sig methodReturnType];
    returnType = removeTypeEncodingPrefix(returnType);
    MFValue *retValue;
    if (*returnType != 'v') {
        void *retValuePointer = malloc([sig methodReturnLength]);
        [invocation getReturnValue:retValuePointer];
        NSString *selectorName = NSStringFromSelector(sel);
        if ([selectorName isEqualToString:@"alloc"] || [selectorName isEqualToString:@"new"] ||
            [selectorName isEqualToString:@"copy"] || [selectorName isEqualToString:@"mutableCopy"]) {
            retValue = [[MFValue alloc] initWithCValuePointer:retValuePointer typeEncoding:returnType bridgeTransfer:YES];
        }else{
            retValue = [[MFValue alloc] initWithCValuePointer:retValuePointer typeEncoding:returnType bridgeTransfer:NO];
        }
        
        free(retValuePointer);
    }else{
        retValue = [MFValue voidValueInstance];
    }
    return retValue;
}



static MFValue *invoke(NSUInteger line, MFInterpreter *inter, MFScopeChain *scope, id instance, SEL sel, NSArray<MFExpression *> *argExprs){
    if (!instance) {
//        for (MFExpression *argExpr in argExprs) {
//            execute_expression(inter, scope, argExpr);
//            [inter.stack pop];
//        }
        return [MFValue valueInstanceWithInt:0];
    }
    
    NSMutableArray<MFValue *> *values = [NSMutableArray arrayWithCapacity:argExprs.count];
    for (MFExpression *expr in argExprs) {
        MFValue *argValue = execute_expression(inter, scope, expr);
        [values addObject:argValue];
    }
    return invoke_values(instance, sel, values);
}


static MFValue *invoke_sueper_values(id instance, Class superClass, SEL sel, NSArray<MFValue *> *argValues){
    struct objc_super *superPtr = &(struct objc_super){instance,superClass};
    NSMethodSignature *sig = [instance methodSignatureForSelector:sel];
    NSUInteger argCount = sig.numberOfArguments;
    
    void **args = alloca(sizeof(void *) * argCount);
    ffi_type **argTypes = alloca(sizeof(ffi_type *) * argCount);
    
    argTypes[0] = &ffi_type_pointer;
    args[0] = &superPtr;
    
    argTypes[1] = &ffi_type_pointer;
    args[1] = &sel;
    
    for (NSUInteger i = 2; i < argCount; i++) {
        MFValue *argValue = argValues[i-2];
        char *argTypeEncoding = (char *)[sig getArgumentTypeAtIndex:i];
        argTypeEncoding = removeTypeEncodingPrefix(argTypeEncoding);
        
        
#define mf_SET_FFI_TYPE_AND_ARG_CASE(_code, _type, _ffi_type_value, _sel)\
case _code:{\
argTypes[i] = &_ffi_type_value;\
_type value = (_type)argValue._sel;\
args[i] = &value;\
break;\
}
        
        switch (*argTypeEncoding) {
                mf_SET_FFI_TYPE_AND_ARG_CASE('c', char, ffi_type_schar, c2integerValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('i', int, ffi_type_sint, c2integerValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('s', short, ffi_type_sshort, c2integerValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('l', long, ffi_type_slong, c2integerValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('q', long long, ffi_type_sint64, c2integerValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('C', unsigned char, ffi_type_uchar, c2uintValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('I', unsigned int, ffi_type_uint, c2uintValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('S', unsigned short, ffi_type_ushort, c2uintValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('L', unsigned long, ffi_type_ulong, c2uintValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('Q', unsigned long long, ffi_type_uint64, c2uintValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('B', BOOL, ffi_type_sint8, c2uintValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('f', float, ffi_type_float, c2doubleValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('d', double, ffi_type_double, c2doubleValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('@', id, ffi_type_pointer, c2objectValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('#', Class, ffi_type_pointer, c2objectValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE(':', SEL, ffi_type_pointer, selValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('*', char *, ffi_type_pointer, c2pointerValue)
                mf_SET_FFI_TYPE_AND_ARG_CASE('^', id, ffi_type_pointer, c2pointerValue)
                
            case '{':{
                argTypes[i] = mf_ffi_type_with_type_encoding(argTypeEncoding);
                if (argValue.type.typeKind == MF_TYPE_STRUCT_LITERAL) {
                    size_t structSize = mf_size_with_encoding(argTypeEncoding);
                    void * structPtr = alloca(structSize);
                    MFStructDeclareTable *table = [MFStructDeclareTable shareInstance];
                    NSString *structName = mf_struct_name_with_encoding(argTypeEncoding);
                    MFStructDeclare *declare = [table getStructDeclareWithName:structName];
                    mf_struct_data_with_dic(structPtr, argValue.objectValue, declare);
                    args[i] = structPtr;
                }else if (argValue.type.typeKind == MF_TYPE_STRUCT){
                    args[i] = argValue.pointerValue;
                }else{
                    NSCAssert(0, @"");
                }
                break;
            }
                
                
            default:
                NSCAssert(0, @"not support type  %s", argTypeEncoding);
                break;
        }
        
    }
    
    char *returnTypeEncoding = (char *)[sig methodReturnType];
    returnTypeEncoding = removeTypeEncodingPrefix(returnTypeEncoding);
    ffi_type *rtype = NULL;
    void *rvalue = NULL;
#define mf_FFI_RETURN_TYPE_CASE(_code, _ffi_type)\
case _code:{\
rtype = &_ffi_type;\
rvalue = alloca(rtype->size);\
break;\
}
    
    switch (*returnTypeEncoding) {
            mf_FFI_RETURN_TYPE_CASE('c', ffi_type_schar)
            mf_FFI_RETURN_TYPE_CASE('i', ffi_type_sint)
            mf_FFI_RETURN_TYPE_CASE('s', ffi_type_sshort)
            mf_FFI_RETURN_TYPE_CASE('l', ffi_type_slong)
            mf_FFI_RETURN_TYPE_CASE('q', ffi_type_sint64)
            mf_FFI_RETURN_TYPE_CASE('C', ffi_type_uchar)
            mf_FFI_RETURN_TYPE_CASE('I', ffi_type_uint)
            mf_FFI_RETURN_TYPE_CASE('S', ffi_type_ushort)
            mf_FFI_RETURN_TYPE_CASE('L', ffi_type_ulong)
            mf_FFI_RETURN_TYPE_CASE('Q', ffi_type_uint64)
            mf_FFI_RETURN_TYPE_CASE('B', ffi_type_sint8)
            mf_FFI_RETURN_TYPE_CASE('f', ffi_type_float)
            mf_FFI_RETURN_TYPE_CASE('d', ffi_type_double)
            mf_FFI_RETURN_TYPE_CASE('@', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('#', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE(':', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('^', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('*', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('v', ffi_type_void)
        case '{':{
            rtype = mf_ffi_type_with_type_encoding(returnTypeEncoding);
            rvalue = alloca(rtype->size);
        }
            
        default:
            NSCAssert(0, @"not support type  %s", returnTypeEncoding);
            break;
    }
    
    
    ffi_cif cif;
    ffi_prep_cif(&cif, FFI_DEFAULT_ABI, (unsigned int)argCount, rtype, argTypes);
    ffi_call(&cif, objc_msgSendSuper, rvalue, args);
    MFValue *retValue;
    if (*returnTypeEncoding != 'v') {
        retValue = [[MFValue alloc] initWithCValuePointer:rvalue typeEncoding:returnTypeEncoding bridgeTransfer:NO];
    }else{
        retValue = [MFValue voidValueInstance];
    }
    return retValue;
}

static MFValue *invoke_super(NSUInteger line, MFInterpreter *inter, MFScopeChain *scope, id instance,Class superClass, SEL sel, NSArray<MFExpression *> *argExprs){
    if (!instance) {
//        for (MFExpression *argExpr in argExprs) {
//            execute_expression(inter, scope, argExpr);
//            [inter.stack pop];
//        }
        return [MFValue valueInstanceWithInt:0];
    }
    NSMutableArray<MFValue *> *values = [NSMutableArray arrayWithCapacity:argExprs.count];
    for (MFExpression *expr in argExprs) {
        MFValue *argValue = execute_expression(inter, scope, expr);
        [values addObject:argValue];
    }
    return invoke_sueper_values(instance,superClass, sel, values);
}







static MFValue *get_struct_field_value(void *structData,MFStructDeclare *declare,NSString *key){
    NSString *typeEncoding = [NSString stringWithUTF8String:declare.typeEncoding];
    NSString *types = [typeEncoding substringToIndex:typeEncoding.length-1];
    NSUInteger location = [types rangeOfString:@"="].location + 1;
    types = [types substringFromIndex:location];
    const char *encoding = types.UTF8String;
    size_t postion = 0;
    NSUInteger index = [declare.keys indexOfObject:key];
    if (index == NSNotFound) {
        NSCAssert(0, @"key %@ not found of struct %@", key, declare.name);
    }
    MFValue *retValue = [[MFValue alloc] init];
    NSUInteger i = 0;
    for (size_t j = 0; j < declare.keys.count; j++) {
#define mf_GET_STRUCT_FIELD_VALUE_CASE(_code,_type,_kind,_sel)\
case _code:{\
if (j == index) {\
_type value = *(_type *)(structData + postion);\
retValue.type = mf_create_type_specifier(_kind);\
retValue._sel = value;\
return retValue;\
}\
postion += sizeof(_type);\
break;\
}
        switch (encoding[i]) {
                mf_GET_STRUCT_FIELD_VALUE_CASE('c',char,MF_TYPE_INT,integerValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('i',int,MF_TYPE_INT,integerValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('s',short,MF_TYPE_INT,integerValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('l',long,MF_TYPE_INT,integerValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('q',long long,MF_TYPE_INT,integerValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('C',unsigned char,MF_TYPE_U_INT,uintValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('I',unsigned int,MF_TYPE_U_INT,uintValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('S',unsigned short,MF_TYPE_U_INT,uintValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('L',unsigned long,MF_TYPE_U_INT,uintValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('Q',unsigned long long,MF_TYPE_U_INT,uintValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('f',float,MF_TYPE_DOUBLE,doubleValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('d',double,MF_TYPE_DOUBLE,doubleValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('B',BOOL,MF_TYPE_U_INT,uintValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('^',void *,MF_TYPE_POINTER,pointerValue);
                mf_GET_STRUCT_FIELD_VALUE_CASE('*',char *,MF_TYPE_C_STRING,cstringValue);
                
                
            case '{':{
                size_t stackSize = 1;
                size_t end = i + 1;
                for (char c = encoding[end]; c ; end++, c = encoding[end]) {
                    if (c == '{') {
                        stackSize++;
                    }else if (c == '}') {
                        stackSize--;
                        if (stackSize == 0) {
                            break;
                        }
                    }
                }
                
                NSString *subTypeEncoding = [types substringWithRange:NSMakeRange(i, end - i + 1)];
                size_t size = mf_size_with_encoding(subTypeEncoding.UTF8String);
                if(j == index){
                    void *value = structData + postion;
                    MFValue *retValue = [MFValue valueInstanceWithStruct:value typeEncoding:subTypeEncoding.UTF8String copyData:NO];
                    return retValue;
                }
                
                
                postion += size;
                i = end;
                break;
            }
            default:
                break;
        }
        i++;
    }
    NSCAssert(0, @"struct %@ typeEncoding error %@", declare.name, typeEncoding);
    return nil;
}


static void set_struct_field_value(void *structData,MFStructDeclare *declare,NSString *key, MFValue *value){
    NSString *typeEncoding = [NSString stringWithUTF8String:declare.typeEncoding];
    NSString *types = [typeEncoding substringToIndex:typeEncoding.length-1];
    NSUInteger location = [types rangeOfString:@"="].location+1;
    types = [types substringFromIndex:location];
    const char *encoding = types.UTF8String;
    size_t postion = 0;
    NSUInteger index = [declare.keys indexOfObject:key];
    if (index == NSNotFound) {
        NSCAssert(0, @"key %@ not found of struct %@", key, declare.name);
    }
    NSUInteger i = 0;
    for (size_t j = 0; j < declare.keys.count; j++) {
#define mf_SET_STRUCT_FIELD_VALUE_CASE(_code,_type,_sel)\
case _code:{\
if (j == index) {\
*(_type *)(structData + postion) = (_type)value._sel;\
return ;\
}\
postion += sizeof(_type);\
break;\
}
        switch (encoding[i]) {
                mf_SET_STRUCT_FIELD_VALUE_CASE('c',char,c2integerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('i',int,c2integerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('s',short,c2integerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('l',long,c2integerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('q',long long,c2integerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('C',unsigned char,c2uintValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('I',unsigned int,c2uintValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('S',unsigned short,c2uintValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('L',unsigned long,c2uintValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('Q',unsigned long long,c2uintValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('f',float,c2doubleValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('d',double,c2doubleValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('B',BOOL,c2integerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('^',void *,c2pointerValue);
                mf_SET_STRUCT_FIELD_VALUE_CASE('*',char *,cstringValue);
                
                
            case '{':{
                size_t stackSize = 1;
                size_t end = i + 1;
                for (char c = encoding[end]; c ; end++, c = encoding[end]) {
                    if (c == '{') {
                        stackSize++;
                    }else if (c == '}') {
                        stackSize--;
                        if (stackSize == 0) {
                            break;
                        }
                    }
                }
                
                NSString *subTypeEncoding = [types substringWithRange:NSMakeRange(i, end - i + 1)];
                size_t size = mf_size_with_encoding(subTypeEncoding.UTF8String);
                if(j == index){
                    void *valuePtr = structData + postion;
                    [value assignToCValuePointer:valuePtr typeEncoding:subTypeEncoding.UTF8String];
                    return;
                }
                postion += size;
                i = end;
                break;
            }
            default:
                break;
        }
        i++;
    }
}




static MFValue * eval_bool_exprseeion(MFInterpreter *inter, MFExpression *expr){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_BOOL);
	value.uintValue = expr.boolValue;
	return value;
}

static MFValue * eval_u_interger_expression(MFInterpreter *inter, MFExpression *expr){
    MFValue *value = [MFValue new];
    value.type = mf_create_type_specifier(MF_TYPE_U_INT);
    value.uintValue = expr.uintValue;
    return value;
}

static MFValue * eval_interger_expression(MFInterpreter *inter, MFExpression *expr){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_INT);
	value.integerValue = expr.integerValue;
	return value;
}

static MFValue * eval_double_expression(MFInterpreter *inter, MFExpression *expr){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_DOUBLE);
	value.doubleValue = expr.doubleValue;
    return value;
}

static MFValue * eval_string_expression(MFInterpreter *inter, MFExpression *expr){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_C_STRING);
	value.cstringValue = expr.cstringValue;
	return value;
}

static MFValue * eval_sel_expression(MFInterpreter *inter, MFExpression *expr){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_SEL);
	value.selValue = NSSelectorFromString(expr.selectorName);
	return value;
}


static void copy_undef_var(id exprOrStatement, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *endScope,MFScopeChain *destScope){
    if (!exprOrStatement) {
        return;
    }
    Class exprOrStatementClass = [exprOrStatement class];
    if (exprOrStatementClass == MFExpression.class) {
        MFExpression *expr = (MFExpression *)exprOrStatement;
        if (expr.expressionKind == MF_SELF_EXPRESSION || expr.expressionKind == MF_SUPER_EXPRESSION) {
            NSString *identifier = @"self";
            if (![chain isInChain:identifier]) {
                MFValue *value = [fromScope getValueWithIdentifier:identifier endScope:endScope];
                if (value) {
                    [destScope setValue:value withIndentifier:identifier];
                }
            }
            return;
        }
    }else if (exprOrStatementClass == MFIdentifierExpression.class) {
        MFIdentifierExpression *expr = (MFIdentifierExpression *)exprOrStatement;
        NSString *identifier = expr.identifier;
        if (![chain isInChain:identifier]) {
           MFValue *value = [fromScope getValueWithIdentifier:identifier endScope:endScope];
            if (value) {
                [destScope setValue:value withIndentifier:identifier];
            }
        }
        return;
        
    }else if (exprOrStatementClass == MFAssignExpression.class) {
        MFAssignExpression *expr = (MFAssignExpression *)exprOrStatement;
        copy_undef_var(expr.left, chain, fromScope, endScope, destScope);
        copy_undef_var(expr.right, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFBinaryExpression.class){
        MFBinaryExpression *expr = (MFBinaryExpression *)exprOrStatement;
        copy_undef_var(expr.left, chain, fromScope, endScope, destScope);
        copy_undef_var(expr.right, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFTernaryExpression.class){
        MFTernaryExpression *expr = (MFTernaryExpression *)exprOrStatement;
        copy_undef_var(expr.condition, chain, fromScope, endScope, destScope);
        copy_undef_var(expr.trueExpr, chain, fromScope, endScope, destScope);
        copy_undef_var(expr.falseExpr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFUnaryExpression.class){
        MFUnaryExpression *expr = (MFUnaryExpression *)exprOrStatement;
        copy_undef_var(expr.expr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFMemberExpression.class){
        MFMemberExpression *expr = (MFMemberExpression *)exprOrStatement;
        copy_undef_var(expr.expr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFFunctonCallExpression.class){
        MFFunctonCallExpression *expr = (MFFunctonCallExpression *)exprOrStatement;
        copy_undef_var(expr.expr, chain, fromScope, endScope, destScope);
        for (MFExpression *argExpr in expr.args) {
            copy_undef_var(argExpr, chain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFSubScriptExpression.class){
        MFSubScriptExpression *expr = (MFSubScriptExpression *)exprOrStatement;
        copy_undef_var(expr.aboveExpr, chain, fromScope, endScope, destScope);
        copy_undef_var(expr.bottomExpr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFStructEntry.class){
        MFStructEntry *expr = (MFStructEntry *)exprOrStatement;
        copy_undef_var(expr.valueExpr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFStructpression.class){
        MFStructpression *expr = (MFStructpression *)exprOrStatement;
        for (MFExpression *entryExpr in expr.entriesExpr) {
            copy_undef_var(entryExpr, chain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFDicEntry.class){
        MFDicEntry *expr = (MFDicEntry *)exprOrStatement;
        copy_undef_var(expr.keyExpr, chain, fromScope, endScope, destScope);
        copy_undef_var(expr.valueExpr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFDictionaryExpression.class){
        MFDictionaryExpression *expr = (MFDictionaryExpression *)exprOrStatement;
        for (MFExpression *entryExpr in expr.entriesExpr) {
            copy_undef_var(entryExpr, chain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFArrayExpression.class){
        MFArrayExpression *expr = (MFArrayExpression *)exprOrStatement;
        for (MFExpression *itemExpression in expr.itemExpressions) {
            copy_undef_var(itemExpression, chain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFBlockExpression.class){
        MFBlockExpression *expr = (MFBlockExpression *)exprOrStatement;
        MFFunctionDefinition *funcDef = expr.func;
        MFVarDeclareChain *funcChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        NSArray *params = funcDef.params;
        for (MFParameter *param in params) {
            NSString *name = param.name;
            [funcChain addIndentifer:name];
        }
        MFBlockBody *funcDefBody = funcDef.block;
        for (MFStatement *statement in funcDefBody.statementList) {
            copy_undef_var(statement, funcChain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFExpressionStatement.class){
        MFExpressionStatement *statement = (MFExpressionStatement *)exprOrStatement;
        copy_undef_var(statement.expr, chain, fromScope, endScope, destScope);
        return;
        
    }else if (exprOrStatementClass == MFDeclarationStatement.class){
        MFDeclarationStatement *statement = (MFDeclarationStatement *)exprOrStatement;
        NSString *name = statement.declaration.name;
        [chain addIndentifer:name];
        
        MFExpression *initializerExpr = statement.declaration.initializer;
        if (initializerExpr) {
            copy_undef_var(initializerExpr, chain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFIfStatement.class){
        MFIfStatement *ifStatement = (MFIfStatement *)exprOrStatement;
        copy_undef_var(ifStatement.condition, chain, fromScope, endScope, destScope);
        
        MFVarDeclareChain *thenChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *statement in ifStatement.thenBlock.statementList) {
            copy_undef_var(statement, thenChain, fromScope, endScope, destScope);
        }
        MFVarDeclareChain *elseChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *statement in ifStatement.elseBlocl.statementList) {
            copy_undef_var(statement, elseChain, fromScope, endScope, destScope);
        }
        
        for (MFElseIf *elseIf in ifStatement.elseIfList) {
            copy_undef_var(elseIf, chain, fromScope, endScope, destScope);
        }
        return;
    }else if (exprOrStatementClass == MFElseIf.class){
        MFElseIf *elseIfStatement = (MFElseIf *)exprOrStatement;
        copy_undef_var(elseIfStatement.condition, chain, fromScope, endScope, destScope);
        MFVarDeclareChain *elseIfChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *statement in elseIfStatement.thenBlock.statementList) {
            copy_undef_var(statement, elseIfChain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFSwitchStatement.class){
        MFSwitchStatement *swithcStatement = (MFSwitchStatement *)exprOrStatement;
        copy_undef_var(swithcStatement.expr, chain, fromScope, endScope, destScope);
        
        for (MFCase *case_ in swithcStatement.caseList) {
            copy_undef_var(case_, chain, fromScope, endScope, destScope);
        }
        
        MFVarDeclareChain *defChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *satement in swithcStatement.defaultBlock.statementList) {
            copy_undef_var(satement, defChain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFCase.class){
        MFCase *caseStatement = (MFCase *)exprOrStatement;
        copy_undef_var(caseStatement.expr, chain, fromScope, endScope, destScope);
        MFVarDeclareChain *caseChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *satement in caseStatement.block.statementList) {
            copy_undef_var(satement, caseChain, fromScope, endScope, destScope);
        }
        return;
        
    }else if (exprOrStatementClass == MFForStatement.class){
        MFForStatement *forStatement = (MFForStatement *)exprOrStatement;
        copy_undef_var(forStatement.initializerExpr, chain, fromScope, endScope, destScope);
        
        MFDeclaration *declaration = forStatement.declaration;
        MFVarDeclareChain *forChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        if (declaration) {
            NSString *name = declaration.name;
            [forChain addIndentifer:name];
        }
        copy_undef_var(forStatement.condition, forChain, fromScope, endScope, destScope);
        
        for (MFStatement *statement in forStatement.block.statementList) {
            copy_undef_var(statement, forChain, fromScope, endScope, destScope);
        }
        
        copy_undef_var(forStatement.post, forChain, fromScope, endScope, destScope);
        
        
    }else if (exprOrStatementClass == MFForEachStatement.class){
        MFForEachStatement *forEachStatement = (MFForEachStatement *)exprOrStatement;
        copy_undef_var(forEachStatement.identifierExpr, chain, fromScope, endScope, destScope);
        
        copy_undef_var(forEachStatement.collectionExpr, chain, fromScope, endScope, destScope);
        
        MFVarDeclareChain *forEachChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        MFDeclaration *declaration = forEachStatement.declaration;
        if (declaration) {
            NSString *name = declaration.name;
            [forEachChain addIndentifer:name];
        }
        for (MFStatement *statement in forEachStatement.block.statementList) {
            copy_undef_var(statement, forEachChain, fromScope, endScope, destScope);
        }
        
        
    }else if (exprOrStatementClass == MFWhileStatement.class){
        MFWhileStatement *whileStatement = (MFWhileStatement *)exprOrStatement;
        copy_undef_var(whileStatement.condition, chain, fromScope, endScope, destScope);
        
        MFVarDeclareChain *whileChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *statement in whileStatement.block.statementList) {
            copy_undef_var(statement, whileChain, fromScope, endScope, destScope);
        }
        
    }else if (exprOrStatementClass == MFDoWhileStatement.class){
        MFWhileStatement *doWhileStatement = (MFWhileStatement *)exprOrStatement;
        copy_undef_var(doWhileStatement.condition, chain, fromScope, endScope, destScope);
        
        MFVarDeclareChain *doWhileChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        for (MFStatement *statement in doWhileStatement.block.statementList) {
            copy_undef_var(statement, doWhileChain, fromScope, endScope, destScope);
        }
        
    }else if (exprOrStatementClass == MFReturnStatement.class){
        MFReturnStatement *returnStatement = (MFReturnStatement *)exprOrStatement;
        copy_undef_var(returnStatement.retValExpr, chain, fromScope, endScope, destScope);
        return;
    }else if (exprOrStatementClass == MFContinueStatement.class){
        
    }else if (exprOrStatementClass == MFBreakStatement.class){
        
    }
    
}



static MFValue *eval_block_expression(MFInterpreter *inter, MFScopeChain *outScope, MFBlockExpression *expr){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_BLOCK);
	MFBlock *manBlock = [[MFBlock alloc] init];
	manBlock.func = expr.func;
	
	MFScopeChain *scope = [MFScopeChain scopeChainWithNext:inter.topScope];
    copy_undef_var(expr, [[MFVarDeclareChain alloc] init], outScope, inter.topScope, scope);
	manBlock.outScope = scope;
	
	manBlock.inter = inter;
	
	const char *typeEncoding = [manBlock.func.returnTypeSpecifier typeEncoding];
	typeEncoding = mf_str_append(typeEncoding, "@?");
	for (MFParameter *param in manBlock.func.params) {
		const char *paramTypeEncoding = [param.type typeEncoding];
		typeEncoding = mf_str_append(typeEncoding, paramTypeEncoding);
	}
	manBlock.typeEncoding = typeEncoding;
	__autoreleasing id ocBlock = [manBlock ocBlock];
	value.objectValue = ocBlock;
    CFRelease((__bridge void *)ocBlock);
    return value;
}


static MFValue * eval_nil_expr(MFInterpreter *inter){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_OBJECT);
	value.objectValue = nil;
	return value;
}


static MFValue * eval_null_expr(MFInterpreter *inter){
	MFValue *value = [MFValue new];
	value.type = mf_create_type_specifier(MF_TYPE_POINTER);
	value.pointerValue = NULL;
	return value;
}


static MFValue *eval_identifer_expression(MFInterpreter *inter, MFScopeChain *scope ,MFIdentifierExpression *expr){
	NSString *identifier = expr.identifier;
	MFValue *value = [scope getValueWithIdentifierInChain:identifier];
	if (!value) {
		Class clazz = NSClassFromString(identifier);
		if (clazz) {
			value = [MFValue valueInstanceWithClass:clazz];
		}
	}
	NSCAssert(value, @"not found var %@", identifier);
	return value;
}


static MFValue * execute_ternary_expression(MFInterpreter *inter, MFScopeChain *scope, MFTernaryExpression *expr){
	MFValue *conValue = execute_expression(inter, scope, expr.condition);
	if (conValue.isSubtantial) {
		if (expr.trueExpr) {
			return execute_expression(inter, scope, expr.trueExpr);
		}else{
            return conValue;
		}
	}else{
		return execute_expression(inter, scope, expr.falseExpr);
	}
	
}


static MFValue * execute_function_call_expression(MFInterpreter *inter, MFScopeChain *scope, MFFunctonCallExpression *expr);
static MFValue * invoke_values(id instance, SEL sel, NSArray<MFValue *> *values);


static MFValue *execute_assign_expression(MFInterpreter *inter, MFScopeChain *scope, MFAssignExpression *expr){
	MFAssignKind assignKind = expr.assignKind;
	MFExpression *leftExpr = expr.left;
	MFExpression *rightExpr = expr.right;
	
	switch (leftExpr.expressionKind) {
        case MF_IDENTIFIER_EXPRESSION:
		case MF_MEMBER_EXPRESSION:{
			MFExpression *optrExpr;
			if (assignKind == MF_NORMAL_ASSIGN) {
				optrExpr = rightExpr;
			}else{
                MFBinaryExpression *binExpr = [[MFBinaryExpression alloc] init];
                binExpr.left = leftExpr;
                binExpr.right = rightExpr;
                optrExpr = binExpr;
				switch (assignKind) {
					case MF_ADD_ASSIGN:{
						binExpr.expressionKind = MF_ADD_EXPRESSION;
						break;
					}
					case MF_SUB_ASSIGN:{
						binExpr.expressionKind = MF_SUB_EXPRESSION;
						break;
					}
					case MF_MUL_ASSIGN:{
						binExpr.expressionKind = MF_MUL_EXPRESSION;
						break;
					}
					case MF_DIV_ASSIGN:{
						binExpr.expressionKind = MF_DIV_EXPRESSION;
						break;
					}
					case MF_MOD_ASSIGN:{
						binExpr.expressionKind = MF_MOD_EXPRESSION;
						break;
					}
					default:
						break;
				}
				
            }
            
            MFValue *operValue = execute_expression(inter, scope, optrExpr);
            if (leftExpr.expressionKind == MF_IDENTIFIER_EXPRESSION) {
                MFIdentifierExpression *identiferExpr = (MFIdentifierExpression *)leftExpr;
                [scope assignWithIdentifer:identiferExpr.identifier value:operValue];
            }else{
                MFMemberExpression *memberExpr = (MFMemberExpression *)leftExpr;
                MFValue *memberObjValue = execute_expression(inter, scope, memberExpr.expr);
                if (memberObjValue.type.typeKind == MF_TYPE_STRUCT) {
                    MFStructDeclareTable *table = [MFStructDeclareTable shareInstance];
                    set_struct_field_value(memberObjValue.pointerValue, [table getStructDeclareWithName:memberObjValue.type.structName],  memberExpr.memberName, operValue);
                }else{
                    if (memberObjValue.type.typeKind != MF_TYPE_OBJECT && memberObjValue.type.typeKind != MF_TYPE_CLASS) {
                        NSCAssert(0, @"line:%zd, %@ is not object",memberExpr.expr.lineNumber, memberObjValue.type.typeName);
                    }
                    //调用对象setter方法
                    NSString *memberName = memberExpr.memberName;
                    NSString *first = [[memberName substringToIndex:1] uppercaseString];
                    NSString *other = memberName.length > 1 ? [memberName substringFromIndex:1] : nil;
                    memberName = [NSString stringWithFormat:@"set%@%@:",first,other];
                    if (memberExpr.expr.expressionKind == MF_SUPER_EXPRESSION) {
                        Class currentClass = objc_getClass(memberExpr.expr.currentClassName.UTF8String);
                        Class superClass = class_getSuperclass(currentClass);
                        invoke_sueper_values([memberObjValue c2objectValue], superClass, NSSelectorFromString(memberName), @[operValue]);
                    }else{
                        invoke_values([memberObjValue c2objectValue], NSSelectorFromString(memberName), @[operValue]);
                    }
                }
            }
            return operValue;
		}
		case MF_SELF_EXPRESSION:{
			NSCAssert(assignKind == MF_NORMAL_ASSIGN, @"");
			MFValue *rightValue = execute_expression(inter, scope, rightExpr);
			[scope assignWithIdentifer:@"self" value:rightValue];
			return rightValue;
		}
			
		case MF_SUB_SCRIPT_EXPRESSION:{
			MFSubScriptExpression *subScriptExpr = (MFSubScriptExpression *)leftExpr;
			MFValue *rightValue = execute_expression(inter, scope, rightExpr);
			MFValue *aboveValue = execute_expression(inter, scope, subScriptExpr.aboveExpr);
			MFValue *bottomValue = execute_expression(inter, scope, subScriptExpr.bottomExpr);
			switch (bottomValue.type.typeKind) {
				case MF_TYPE_BOOL:
				case MF_TYPE_INT:
				case MF_TYPE_U_INT:
					aboveValue.objectValue[bottomValue.c2integerValue] = rightValue.objectValue;
					break;
				case MF_TYPE_CLASS:
					aboveValue.objectValue[(id<NSCopying>)bottomValue.classValue] = rightValue.objectValue;
					break;
				case MF_TYPE_OBJECT:
				case MF_TYPE_BLOCK:
					aboveValue.objectValue[bottomValue.objectValue] = rightValue.objectValue;
					break;
				default:
					NSCAssert(0, @"");
					break;
			}
            return rightValue;
		}
		default:
			NSCAssert(0, @"");
			return nil;
	}

}


#define arithmeticalOperation(operation,operationName) \
if (leftValue.type.typeKind == MF_TYPE_DOUBLE || rightValue.type.typeKind == MF_TYPE_DOUBLE) {\
resultValue.type = mf_create_type_specifier(MF_TYPE_DOUBLE);\
if (leftValue.type.typeKind == MF_TYPE_DOUBLE) {\
switch (rightValue.type.typeKind) {\
case MF_TYPE_DOUBLE:\
resultValue.doubleValue = leftValue.doubleValue operation rightValue.doubleValue;\
break;\
case MF_TYPE_INT:\
resultValue.doubleValue = leftValue.doubleValue operation rightValue.integerValue;\
break;\
case MF_TYPE_U_INT:\
resultValue.doubleValue = leftValue.doubleValue operation rightValue.uintValue;\
break;\
default:\
NSCAssert(0, @"line:%zd, " #operationName  " operation not support type: %@",expr.right.lineNumber ,rightValue.type.typeName);\
break;\
}\
}else{\
switch (leftValue.type.typeKind) {\
case MF_TYPE_INT:\
resultValue.doubleValue = leftValue.integerValue operation rightValue.doubleValue;\
break;\
case MF_TYPE_U_INT:\
resultValue.doubleValue = leftValue.uintValue operation rightValue.doubleValue;\
break;\
default:\
NSCAssert(0, @"line:%zd, " #operationName  " operation not support type: %@",expr.left.lineNumber ,leftValue.type.typeName);\
break;\
}\
}\
}else if (leftValue.type.typeKind == MF_TYPE_INT || rightValue.type.typeKind == MF_TYPE_INT){\
resultValue.type = mf_create_type_specifier(MF_TYPE_INT);\
if (leftValue.type.typeKind == MF_TYPE_INT) {\
switch (rightValue.type.typeKind) {\
case MF_TYPE_INT:\
resultValue.integerValue = leftValue.integerValue operation rightValue.integerValue;\
break;\
case MF_TYPE_U_INT:\
resultValue.integerValue = leftValue.integerValue operation rightValue.uintValue;\
break;\
default:\
NSCAssert(0, @"line:%zd, " #operationName  " operation not support type: %@",expr.right.lineNumber ,rightValue.type.typeName);\
break;\
}\
}else{\
switch (leftValue.type.typeKind) {\
case MF_TYPE_U_INT:\
resultValue.integerValue = leftValue.uintValue operation rightValue.integerValue;\
break;\
default:\
NSCAssert(0, @"line:%zd, " #operationName  " operation not support type: %@",expr.left.lineNumber ,leftValue.type.typeName);\
break;\
}\
}\
}else if (leftValue.type.typeKind == MF_TYPE_U_INT && rightValue.type.typeKind == MF_TYPE_U_INT){\
resultValue.type = mf_create_type_specifier(MF_TYPE_U_INT);\
resultValue.uintValue = leftValue.uintValue operation rightValue.uintValue;\
}else{\
NSCAssert(0, @"line:%zd, " #operationName  " operation not support type: %@",expr.right.lineNumber ,rightValue.type.typeName);\
}


static MFValue * execute_add_expression(MFInterpreter *inter, MFScopeChain *scope,MFBinaryExpression  *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	MFValue *resultValue = [MFValue new];
	
	if (![leftValue isMember] || ![rightValue isMember]){
		resultValue.type = mf_create_type_specifier(MF_TYPE_OBJECT);
		NSString *str = [NSString stringWithFormat:@"%@%@",[leftValue nsStringValue].objectValue,[rightValue nsStringValue].objectValue];
		resultValue.objectValue = str;
	}else arithmeticalOperation(+,add);
    return resultValue;
}


static MFValue * execute_sub_expression(MFInterpreter *inter, MFScopeChain *scope,MFBinaryExpression  *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	MFValue *resultValue = [MFValue new];
	arithmeticalOperation(-,sub);
	return resultValue;
}


static MFValue * execute_mul_expression(MFInterpreter *inter, MFScopeChain *scope,MFBinaryExpression  *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	MFValue *resultValue = [MFValue new];
	arithmeticalOperation(*,mul);
	return resultValue;
}


static MFValue *execute_div_expression(MFInterpreter *inter, MFScopeChain *scope,MFBinaryExpression  *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	switch (rightValue.type.typeKind) {
		case MF_TYPE_DOUBLE:
			if (rightValue.doubleValue == 0) {
				NSCAssert(0, @"line:%zd,divisor cannot be zero!",expr.right.lineNumber);
			}
			break;
		case MF_TYPE_INT:
			if (rightValue.integerValue == 0) {
				NSCAssert(0, @"line:%zd,divisor cannot be zero!",expr.right.lineNumber);
			}
			break;
		case MF_TYPE_U_INT:
			if (rightValue.uintValue == 0) {
				NSCAssert(0, @"line:%zd,divisor cannot be zero!",expr.right.lineNumber);
			}
			break;
			
		default:
			NSCAssert(0, @"line:%zd, div operation not support type: %@",expr.right.lineNumber ,rightValue.type.typeName);
			break;
	}
	MFValue *resultValue = [MFValue new];\
	arithmeticalOperation(/,div);
	return resultValue;
}



static MFValue *execute_mod_expression(MFInterpreter *inter, MFScopeChain *scope,MFBinaryExpression  *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	if (leftValue.type.typeKind != MF_TYPE_INT && leftValue.type.typeKind != MF_TYPE_U_INT) {
		NSCAssert(0, @"line:%zd, mod operation not support type: %@",expr.left.lineNumber ,leftValue.type.typeName);
	}
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	if (rightValue.type.typeKind != MF_TYPE_INT && rightValue.type.typeKind != MF_TYPE_U_INT) {
		NSCAssert(0, @"line:%zd, mod operation not support type: %@",expr.right.lineNumber ,rightValue.type.typeName);
	}
	switch (rightValue.type.typeKind) {
		case MF_TYPE_INT:
			if (rightValue.integerValue == 0) {
				NSCAssert(0, @"line:%zd,mod cannot be zero!",expr.right.lineNumber);
			}
			break;
		case MF_TYPE_U_INT:
			if (rightValue.uintValue == 0) {
				NSCAssert(0, @"line:%zd,mod cannot be zero!",expr.right.lineNumber);
			}
			break;
			
		default:
			NSCAssert(0, @"line:%zd, mod operation not support type: %@",expr.right.lineNumber ,rightValue.type.typeName);
			break;
	}
	MFValue *resultValue = [MFValue new];
	if (leftValue.type.typeKind == MF_TYPE_INT || leftValue.type.typeKind == MF_TYPE_INT) {
		resultValue.type = mf_create_type_specifier(MF_TYPE_INT);
		if (leftValue.type.typeKind == MF_TYPE_INT) {
			if (rightValue.type.typeKind == MF_TYPE_INT) {
				resultValue.integerValue = leftValue.integerValue % rightValue.integerValue;
			}else{
				resultValue.integerValue = leftValue.integerValue % rightValue.uintValue;
			}
		}else{
			resultValue.integerValue = leftValue.uintValue % rightValue.integerValue;
		}
	}else{
		resultValue.type = mf_create_type_specifier(MF_TYPE_U_INT);
		resultValue.uintValue = leftValue.uintValue % rightValue.uintValue;
	}
	return resultValue;
}
#define number_value_compare(sel,oper)\
switch (value2.type.typeKind) {\
case MF_TYPE_BOOL:\
return value1.sel oper value2.uintValue;\
case MF_TYPE_U_INT:\
return value1.sel oper value2.uintValue;\
case MF_TYPE_INT:\
return value1.sel oper value2.integerValue;\
case MF_TYPE_DOUBLE:\
return value1.sel oper value2.doubleValue;\
default:\
NSCAssert(0, @"line:%zd == 、 != 、 < 、 <= 、 > 、 >= can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);\
break;\
}
BOOL mf_equal_value(NSUInteger lineNumber,MFValue *value1, MFValue *value2){

	
#define object_value_equal(sel)\
switch (value2.type.typeKind) {\
case MF_TYPE_CLASS:\
	return value1.sel == value2.classValue;\
case MF_TYPE_OBJECT:\
case MF_TYPE_BLOCK:\
	return value1.sel == value2.objectValue;\
case MF_TYPE_POINTER:\
	return value1.sel == value2.pointerValue;\
default:\
	NSCAssert(0, @"line:%zd == and != can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);\
	break;\
}\

	switch (value1.type.typeKind) {
		case MF_TYPE_BOOL:
		case MF_TYPE_U_INT:{
			number_value_compare(uintValue, ==);
		}
		case MF_TYPE_INT:{
			number_value_compare(integerValue, ==);
		}
		case MF_TYPE_DOUBLE:{
			number_value_compare(doubleValue, ==);
		}
		case MF_TYPE_C_STRING:{
			switch (value2.type.typeKind) {
				case MF_TYPE_C_STRING:
					 return value1.cstringValue == value2.cstringValue;
					break;
				case MF_TYPE_POINTER:
					return value1.cstringValue == value2.pointerValue;
					break;
				default:
					NSCAssert(0, @"line:%zd == and != can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);
					break;
			}
		}
		case MF_TYPE_SEL:{
			if (value2.type.typeKind == MF_TYPE_SEL) {
				return value1.selValue == value2.selValue;
			} else {
				NSCAssert(0, @"line:%zd == and != can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);
			}
		}
		case MF_TYPE_CLASS:{
			object_value_equal(classValue);
		}
		case MF_TYPE_OBJECT:
		case MF_TYPE_BLOCK:{
			object_value_equal(objectValue);
		}
		case MF_TYPE_POINTER:{
			switch (value2.type.typeKind) {
				case MF_TYPE_CLASS:
					return value2.classValue == value1.pointerValue;
				case MF_TYPE_OBJECT:
					return value2.objectValue == value1.pointerValue;
				case MF_TYPE_BLOCK:
					return value2.objectValue == value1.pointerValue;
				case MF_TYPE_POINTER:
					return value2.pointerValue == value1.pointerValue;
				default:
					NSCAssert(0, @"line:%zd == and != can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);
					break;
			}
		}
		case MF_TYPE_STRUCT:{
			if (value2.type.typeKind == MF_TYPE_STRUCT) {
				if ([value1.type.structName isEqualToString:value2.type.structName]) {
					const char *typeEncoding  = [value1.type typeEncoding];
					size_t size = mf_size_with_encoding(typeEncoding);
					return memcmp(value1.pointerValue, value2.pointerValue, size) == 0;
				}else{
					return NO;
				}
			}else{
				NSCAssert(0, @"line:%zd == and != can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);
				break;
			}
		}
		case MF_TYPE_STRUCT_LITERAL:{
			return NO;
		}
			
		default:NSCAssert(0, @"line:%zd == and != can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);
			break;
	}
#undef object_value_equal
	return NO;
}

static MFValue * execute_eq_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	BOOL equal =  mf_equal_value(expr.left.lineNumber, leftValue, rightValue);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = equal;
	return resultValue;
}

static MFValue * execute_ne_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	BOOL equal =  mf_equal_value(expr.left.lineNumber, leftValue, rightValue);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = !equal;
	return resultValue;
}



#define compare_number_func(prefix, oper)\
static BOOL prefix##_value(NSUInteger lineNumber,MFValue  *value1, MFValue  *value2){\
switch (value1.type.typeKind) {\
	case MF_TYPE_BOOL:\
	case MF_TYPE_U_INT:\
		number_value_compare(uintValue, oper);\
	case MF_TYPE_INT:\
		number_value_compare(integerValue, oper);\
	case MF_TYPE_DOUBLE:\
		number_value_compare(doubleValue, oper);\
	default:\
		NSCAssert(0, @"line:%zd == 、 != 、 < 、 <= 、 > 、 >= can not use between %@ and %@",lineNumber, value1.type.typeName, value2.type.typeName);\
		break;\
}\
return NO;\
}

compare_number_func(lt, <)
compare_number_func(le, <=)
compare_number_func(ge, >=)
compare_number_func(gt, >)

static MFValue * execute_lt_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	BOOL lt = lt_value(expr.left.lineNumber, leftValue, rightValue);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = lt;
    return resultValue;
}


static MFValue * execute_le_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	BOOL le = le_value(expr.left.lineNumber, leftValue, rightValue);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = le;
    return resultValue;
}

static MFValue * execute_ge_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	BOOL ge = ge_value(expr.left.lineNumber, leftValue, rightValue);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = ge;
	return resultValue;
}


static MFValue * execute_gt_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *rightValue = execute_expression(inter, scope, expr.right);
	BOOL gt = gt_value(expr.left.lineNumber, leftValue, rightValue);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = gt;
    return resultValue;
}

static MFValue *execute_logic_and_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	if (!leftValue.isSubtantial) {
		resultValue.uintValue = NO;
	}else{
		MFValue *rightValue = execute_expression(inter, scope, expr.right);
		if (!rightValue.isSubtantial) {
			resultValue.uintValue = NO;
		}else{
			resultValue.uintValue = YES;
		}
	}
	return resultValue;
}

static MFValue * execute_logic_or_expression(MFInterpreter *inter, MFScopeChain *scope, MFBinaryExpression *expr){
	MFValue *leftValue = execute_expression(inter, scope, expr.left);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	if (leftValue.isSubtantial) {
		resultValue.uintValue = YES;
	}else{
		MFValue *rightValue = execute_expression(inter, scope, expr.right);
		if (rightValue.isSubtantial) {
			resultValue.uintValue = YES;
		}else{
			resultValue.uintValue = NO;
		}
	}
    return resultValue;
}

static MFValue * execute_logic_not_expression(MFInterpreter *inter, MFScopeChain *scope,MFUnaryExpression *expr){
	MFValue *value = execute_expression(inter, scope, expr.expr);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_BOOL);
	resultValue.uintValue = !value.isSubtantial;
	return resultValue;
}

static MFValue * execute_increment_expression(MFInterpreter *inter, MFScopeChain *scope,MFUnaryExpression *expr){
	MFExpression *oneValueExpr = mf_create_expression(MF_INT_EXPRESSION);
	oneValueExpr.integerValue = 1;
	MFBinaryExpression *addExpr = [[MFBinaryExpression alloc] initWithExpressionKind:MF_ADD_EXPRESSION];
	addExpr.left = expr.expr;
	addExpr.right = oneValueExpr;
	MFAssignExpression *assignExpression = (MFAssignExpression *)mf_create_expression(MF_ASSIGN_EXPRESSION);
	assignExpression.assignKind = MF_NORMAL_ASSIGN;
	assignExpression.left = expr.expr;
	assignExpression.right = addExpr;
	return execute_expression(inter, scope, assignExpression);
}

static MFValue * execute_decrement_expression(MFInterpreter *inter, MFScopeChain *scope,MFUnaryExpression *expr){
	
	MFExpression *oneValueExpr = mf_create_expression(MF_INT_EXPRESSION);
	oneValueExpr.integerValue = 1;
	MFBinaryExpression *addExpr = [[MFBinaryExpression alloc] initWithExpressionKind:MF_SUB_EXPRESSION];
	addExpr.left = expr.expr;
	addExpr.right = oneValueExpr;
	MFAssignExpression *assignExpression = (MFAssignExpression *)mf_create_expression(MF_ASSIGN_EXPRESSION);
	assignExpression.assignKind = MF_NORMAL_ASSIGN;
	assignExpression.left = expr.expr;
	assignExpression.right = addExpr;
	return execute_expression(inter, scope, assignExpression);
	
	
}
static MFValue * execute_negative_expression(MFInterpreter *inter, MFScopeChain *scope,MFUnaryExpression *expr){
	MFValue *value = execute_expression(inter, scope, expr.expr);
	MFValue *resultValue = [MFValue new];
	switch (value.type.typeKind) {
		case MF_TYPE_INT:
			resultValue.type = mf_create_type_specifier(MF_TYPE_INT);
			resultValue.integerValue = -value.integerValue;
			break;
		case MF_TYPE_BOOL:
		case MF_TYPE_U_INT:
			resultValue.type = mf_create_type_specifier(MF_TYPE_U_INT);
			resultValue.integerValue = - value.uintValue;
			break;
		case MF_TYPE_DOUBLE:
			resultValue.type = mf_create_type_specifier(MF_TYPE_DOUBLE);
			resultValue.doubleValue = - value.doubleValue;
			break;
			
		default:
			NSCAssert(0, @"line:%zd operator ‘-’ can not use type: %@",expr.expr.lineNumber, value.type.typeName);
			break;
	}
    return resultValue;
    
}


static MFValue * execute_sub_script_expression(MFInterpreter *inter, MFScopeChain *scope,MFSubScriptExpression *expr){
	MFValue *bottomValue = execute_expression(inter, scope, expr.bottomExpr);
	MFTypeSpecifierKind kind = bottomValue.type.typeKind;
	
	MFValue *arrValue = execute_expression(inter, scope, expr.aboveExpr);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_OBJECT);
	switch (kind) {
		case MF_TYPE_BOOL:
		case MF_TYPE_U_INT:
		case MF_TYPE_INT:
			resultValue.objectValue = arrValue.objectValue[bottomValue.c2integerValue];
			break;
		case MF_TYPE_BLOCK:
		case MF_TYPE_OBJECT:
			resultValue.objectValue = arrValue.objectValue[bottomValue.objectValue];
			break;
		case MF_TYPE_CLASS:
			resultValue.objectValue = arrValue.objectValue[bottomValue.classValue];
			break;
		default:
			NSCAssert(0, @"line:%zd, index operator can not use type: %@",expr.bottomExpr.lineNumber, bottomValue.type.typeName);
			break;
	}
    return resultValue;
}

static MFValue * execute_at_expression(MFInterpreter *inter, MFScopeChain *scope,MFUnaryExpression *expr){
	MFValue *value = execute_expression(inter, scope, expr.expr);
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_OBJECT);
	switch (value.type.typeKind) {
		case MF_TYPE_BOOL:
		case MF_TYPE_U_INT:
			resultValue.objectValue = @(value.uintValue);
			break;
		case MF_TYPE_INT:
			resultValue.objectValue = @(value.integerValue);
			break;
		case MF_TYPE_DOUBLE:
			resultValue.objectValue = @(value.doubleValue);
			break;
		case MF_TYPE_C_STRING:
			resultValue.objectValue = @(value.cstringValue);
			break;
			
		default:
			NSCAssert(0, @"line:%zd operator ‘@’ can not use type: %@",expr.expr.lineNumber, value.type.typeName);
			break;
	}
    return resultValue;
}

static MFValue * execute_get_address_expresion(MFInterpreter *inter, MFScopeChain *scope,MFUnaryExpression *expr){
    MFValue *value = execute_expression(inter, scope, expr.expr);
    MFValue *resultValue = [MFValue new];
    resultValue.type = mf_create_type_specifier(MF_TYPE_POINTER);
    resultValue.pointerValue = [value valuePointer];
    return resultValue;
}


static MFValue * eval_struct_expression(MFInterpreter *inter, MFScopeChain *scope, MFStructpression *expr){
	NSMutableDictionary *structDic = [NSMutableDictionary dictionary];
	NSArray *entriesExpr =  expr.entriesExpr;
	for (MFStructEntry *entryExpr in entriesExpr) {
		NSString *key = entryExpr.key;
		MFExpression *itemExpr =  entryExpr.valueExpr;
		MFValue *value = execute_expression(inter, scope, itemExpr);
		if (value.isObject) {
			NSCAssert(0, @"line:%zd, struct can not support object type %@", itemExpr.lineNumber, value.type.typeName );
		}
		switch (value.type.typeKind) {
			case MF_TYPE_BOOL:
			case MF_TYPE_U_INT:
				structDic[key] = @(value.uintValue);
				break;
			case MF_TYPE_INT:
				structDic[key] = @(value.integerValue);
				break;
			case MF_TYPE_DOUBLE:
				structDic[key] = @(value.doubleValue);
				break;
			case MF_TYPE_C_STRING:
				structDic[key] = [NSValue valueWithPointer:value.cstringValue];
				break;
			case MF_TYPE_SEL:
				structDic[key] = [NSValue valueWithPointer:value.selValue];
				break;
			case MF_TYPE_STRUCT:
				structDic[key] = value;
				break;
			case MF_TYPE_STRUCT_LITERAL:
				structDic[key] = value.objectValue;
				break;
			case MF_TYPE_POINTER:
				structDic[key] = [NSValue valueWithPointer:value.pointerValue];
				break;
				
			default:
				NSCAssert(0, @"");
				break;
		}
	}

	MFValue *result = [[MFValue alloc] init];
	result.type = mf_create_type_specifier(MF_TYPE_STRUCT_LITERAL);
	result.objectValue = [structDic copy];
    return result;
}




static MFValue * execute_dic_expression(MFInterpreter *inter, MFScopeChain *scope, MFDictionaryExpression *expr){
	NSMutableDictionary *dic = [NSMutableDictionary dictionary];
	for (MFDicEntry *entry in expr.entriesExpr) {
		MFValue *keyValue = execute_expression(inter, scope, entry.keyExpr);
		if (!keyValue.isObject) {
			NSCAssert(0, @"line:%zd key can not bee type:%@",entry.keyExpr.lineNumber, keyValue.type.typeName);
		}
		
		MFValue *valueValue = execute_expression(inter, scope, entry.valueExpr);
		if (!valueValue.isObject) {
			NSCAssert(0, @"line:%zd value can not bee type:%@",entry.keyExpr.lineNumber, valueValue.type.typeName);
		}

		dic[keyValue.c2objectValue] = valueValue.c2objectValue;
	}
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_OBJECT);
	resultValue.objectValue = dic.copy;
	return resultValue;
}


static MFValue * execute_array_expression(MFInterpreter *inter, MFScopeChain *scope, MFArrayExpression *expr){
	NSMutableArray *array = [NSMutableArray array];
	for (MFExpression *elementExpr in expr.itemExpressions) {
		MFValue *elementValue = execute_expression(inter, scope, elementExpr);
		if (elementValue.isObject) {
			[array addObject:elementValue.c2objectValue];
		}else{
			NSCAssert(0, @"line:%zd array element type  can not bee type:%@",elementExpr.lineNumber, elementValue.type.typeName);
		}
	}
	MFValue *resultValue = [MFValue new];
	resultValue.type = mf_create_type_specifier(MF_TYPE_OBJECT);
	resultValue.objectValue = array.copy;
	return resultValue;
}


static MFValue * execute_self_super_expression(MFInterpreter *inter, MFScopeChain *scope){
	MFValue *value = [scope getValueWithIdentifierInChain:@"self"];
	NSCAssert(value, @"not found var %@", @"self");
	return value;
}


static MFValue * execute_member_expression(MFInterpreter *inter, MFScopeChain *scope, MFMemberExpression *expr){
    if (expr.expr.expressionKind == MF_SUPER_EXPRESSION) {
        MFFunctonCallExpression *funcExpr = [[MFFunctonCallExpression alloc] init];
        funcExpr.expr = expr;
        return execute_function_call_expression(inter, scope, funcExpr);;
    }
    
	MFValue *obj = execute_expression(inter, scope, expr.expr);
    MFValue *resultValue;
	if (obj.type.typeKind == MF_TYPE_STRUCT) {
		MFStructDeclareTable *table = [MFStructDeclareTable shareInstance];
		resultValue =  get_struct_field_value(obj.pointerValue, [table getStructDeclareWithName:obj.type.structName], expr.memberName);
    }else{
        if (obj.type.typeKind != MF_TYPE_OBJECT && obj.type.typeKind != MF_TYPE_CLASS) {
            NSCAssert(0, @"line:%zd, %@ is not object",expr.expr.lineNumber, obj.type.typeName);
        }
        SEL sel = NSSelectorFromString(expr.memberName);
        resultValue  = invoke_values(obj.c2objectValue, sel, nil);
    }
    return resultValue;
}

static MFValue * call_c_function(NSUInteger lineNumber, MFValue *callee, NSArray<MFValue *> *argValues);

static MFValue * execute_function_call_expression(MFInterpreter *inter, MFScopeChain *scope, MFFunctonCallExpression *expr){
	MFExpressionKind exprKind = expr.expr.expressionKind;
	switch (exprKind) {
		case MF_MEMBER_EXPRESSION:{
			MFMemberExpression *memberExpr = (MFMemberExpression *)expr.expr;
			MFExpression *memberObjExpr = memberExpr.expr;
			SEL sel = NSSelectorFromString(memberExpr.memberName);
			switch (memberObjExpr.expressionKind) {
				case MF_SELF_EXPRESSION:{
					id _self = [[scope getValueWithIdentifierInChain:@"self"] objectValue];
					MFValue *retValue = invoke(expr.lineNumber, inter, scope,_self, sel, expr.args);
					return retValue;
				}
				case MF_SUPER_EXPRESSION:{
					id _self = [[scope getValueWithIdentifierInChain:@"self"] objectValue];
                    Class currentClass = objc_getClass(memberObjExpr.currentClassName.UTF8String);
					Class superClass = class_getSuperclass(currentClass);
                    MFValue *retValue = invoke_super(memberObjExpr.lineNumber, inter, scope, _self, superClass, sel, expr.args);
                    return retValue;
				}
				default:{
					MFValue *memberObj = execute_expression(inter, scope, memberObjExpr);
					MFValue *retValue = invoke(expr.lineNumber, inter, scope, [memberObj c2objectValue], sel, expr.args);
                    return retValue;
				}
			}
			
			
			break;
		}
		case MF_IDENTIFIER_EXPRESSION:
		case MF_FUNCTION_CALL_EXPRESSION:{
			MFValue *callee = execute_expression(inter, scope, expr.expr);
            static Class blockClass = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                blockClass = [^{} class];
                while (blockClass) {
                    Class superClass = class_getSuperclass(blockClass);
                    if (superClass == nil) {
                        break;
                    }
                    blockClass = superClass;
                }
            });
            
            if (callee.type.typeKind != MF_TYPE_C_FUNCTION && !(callee.isObject && [callee.objectValue isKindOfClass:blockClass])) {
                mf_throw_error(expr.expr.lineNumber, MFRuntimeErrorCallCanNotBeCalleeValue, @"type: %@ value can not be callee",callee.type.typeName);
                return nil;
            }
            
            if (callee.type.typeKind == MF_TYPE_C_FUNCTION) {
                if (callee.pointerValue == NULL) {
                    mf_throw_error(expr.expr.lineNumber, MFRuntimeErrorNullPointer, nil);
                    return nil;
                }
                
                NSUInteger paramListCount =  callee.type.paramListTypeEncode.count;
                if (paramListCount != expr.args.count) {
                    mf_throw_error(expr.lineNumber, MFRuntimeErrorParameterListCountNoMatch, @"expect count: %zd, pass in cout:%zd",paramListCount, expr.args.count);
                    return nil;
                }
                
                NSMutableArray *paramValues = [NSMutableArray arrayWithCapacity:paramListCount];
                for (MFExpression *argExpr in expr.args) {
                    MFValue *value = execute_expression(inter, scope, argExpr);
                    [paramValues addObject:value];
                }
                MFValue *retValue = call_c_function(expr.lineNumber,callee, paramValues.copy);
                return retValue;
            }else{
                const char *blockTypeEncoding = [MFBlock typeEncodingForBlock:callee.c2objectValue];
                NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:blockTypeEncoding];
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
                [invocation setTarget:callee.objectValue];
                
                NSUInteger numberOfArguments = [sig numberOfArguments];
                if (numberOfArguments - 1 != expr.args.count) {
                    mf_throw_error(expr.lineNumber, MFRuntimeErrorParameterListCountNoMatch, @"expect count: %zd, pass in cout:%zd",numberOfArguments - 1,expr.args.count);
                    return nil;
                }
                for (NSUInteger i = 1; i < numberOfArguments; i++) {
                    const char *typeEncoding = [sig getArgumentTypeAtIndex:i];
                    void *ptr = alloca(mf_size_with_encoding(typeEncoding));
                    __autoreleasing MFValue *argValue = execute_expression(inter, scope, expr.args[i -1]);
                    [argValue assignToCValuePointer:ptr typeEncoding:typeEncoding];
                    [invocation setArgument:ptr atIndex:i];
                }
                [invocation invoke];
                const char *retType = [sig methodReturnType];
                retType = removeTypeEncodingPrefix((char *)retType);
                MFValue *retValue;
                if (*retType != 'v') {
                    void *retValuePtr = alloca(mf_size_with_encoding(retType));
                    [invocation getReturnValue:retValuePtr];
                    retValue = [[MFValue alloc] initWithCValuePointer:retValuePtr typeEncoding:retType bridgeTransfer:NO];
                }else{
                    retValue = [MFValue voidValueInstance];
                }
                return retValue;
            }
			break;
		}
			
		default:
            mf_throw_error(expr.lineNumber, MFRuntimeErrorCallCanNotBeCalleeValue, @"expression can not be callee");
			return nil;
	}
	
}

static MFValue * call_c_function(NSUInteger lineNumber, MFValue *callee, NSArray<MFValue *> *argValues){
    void *functionPtr = callee.pointerValue;
    NSArray<NSString *> *paramListTypeEncode = callee.type.paramListTypeEncode;
    NSString *returnTypeEncode = callee.type.returnTypeEncode;
    NSUInteger argCount = paramListTypeEncode.count;
    
    ffi_type **ffiArgTypes = alloca(sizeof(ffi_type *) *argCount);
    for (int i = 0; i < argCount; i++) {
        ffiArgTypes[i] = mf_ffi_type_with_type_encoding(paramListTypeEncode[i].UTF8String);
    }
    
    void **ffiArgs = alloca(sizeof(void *) *argCount);
    for (int  i = 0; i < argCount; i++) {
        size_t size = ffiArgTypes[i]->size;
        void *ffiArgPtr = alloca(size);
        ffiArgs[i] = ffiArgPtr;
        MFValue *argValue = argValues[i];
        [argValue assignToCValuePointer:ffiArgPtr typeEncoding:paramListTypeEncode[i].UTF8String];
    }

    ffi_cif cif;
    ffi_type *returnFfiType = mf_ffi_type_with_type_encoding(returnTypeEncode.UTF8String);;
    ffi_status ffiPrepStatus = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, (unsigned int)argCount, returnFfiType, ffiArgTypes);

    if (ffiPrepStatus == FFI_OK) {
        void *returnPtr = NULL;
        if (returnFfiType->size) {
            returnPtr = alloca(returnFfiType->size);
        }
        ffi_call(&cif, functionPtr, returnPtr, ffiArgs);

        MFValue *value = [[MFValue alloc] initWithCValuePointer:returnPtr typeEncoding:returnTypeEncode.UTF8String bridgeTransfer:NO];
        return value;
    }
    mf_throw_error(lineNumber, MFRuntimeErrorCallCFunctionFailure, @"call CFunction failure");
    return nil;
}


static MFValue * execute_cfunction_expression(MFInterpreter *inter, MFScopeChain *scope, MFCFuntionExpression *expr){
    MFExpression *cfunNameOrPointerExpr = expr.cfunNameOrPointerExpr;
    MFValue *cfunNameOrPointer = execute_expression(inter, scope, cfunNameOrPointerExpr);
    if (cfunNameOrPointer.type.typeKind != MF_TYPE_C_STRING && cfunNameOrPointer.type.typeKind != MF_TYPE_POINTER) {
        mf_throw_error(cfunNameOrPointerExpr.lineNumber, MFRuntimeErrorIllegalParameterType, @" CFuntion must accept a CString type or Pointer type, not %@!",cfunNameOrPointer.type.typeName);
        return nil;
    }
    
    MFValue *value = [[MFValue alloc] init];
    MFTypeSpecifier *type = mf_create_type_specifier(MF_TYPE_C_FUNCTION);
    value.type = type;
    
    if (cfunNameOrPointer.type.typeKind == MF_TYPE_C_STRING) {
        void *pointerValue = symdl(cfunNameOrPointer.cstringValue);
        if (!pointerValue) {
            mf_throw_error(cfunNameOrPointerExpr.lineNumber, MFRuntimeErrorNotFoundCFunction, @"not found CFunction: %s",cfunNameOrPointer.cstringValue);
            return nil;
        }
        value.pointerValue = pointerValue;
    }else{
        value.pointerValue = cfunNameOrPointer.pointerValue;
    }
    return value;
}



static MFValue * execute_expression(MFInterpreter *inter, MFScopeChain *scope, __kindof MFExpression *expr){
	switch (expr.expressionKind) {
		case MF_BOOLEAN_EXPRESSION:
			return eval_bool_exprseeion(inter, expr);
        case MF_U_INT_EXPRESSION:
            return eval_u_interger_expression(inter, expr);
		case MF_INT_EXPRESSION:
			return eval_interger_expression(inter, expr);
		case MF_DOUBLE_EXPRESSION:
			return eval_double_expression(inter, expr);
		case MF_STRING_EXPRESSION:
		 	return eval_string_expression(inter, expr);
		case MF_SELECTOR_EXPRESSION:
			return eval_sel_expression(inter, expr);
		case MF_BLOCK_EXPRESSION:
			return eval_block_expression(inter, scope, expr);
		case MF_NIL_EXPRESSION:
			return eval_nil_expr(inter);
		case MF_NULL_EXPRESSION:
			return eval_null_expr(inter);
		case MF_SELF_EXPRESSION:
		case MF_SUPER_EXPRESSION:
			return execute_self_super_expression(inter, scope);
			
		case MF_IDENTIFIER_EXPRESSION:
			return eval_identifer_expression(inter, scope, expr);

		case MF_ASSIGN_EXPRESSION:
			return execute_assign_expression(inter, scope, expr);
		case MF_ADD_EXPRESSION:
			return execute_add_expression(inter, scope, expr);
		case MF_SUB_EXPRESSION:
			return execute_sub_expression(inter, scope, expr);
		case MF_MUL_EXPRESSION:
			return execute_mul_expression(inter, scope, expr);
		case MF_DIV_EXPRESSION:
		 	return execute_div_expression(inter, scope, expr);
		case MF_MOD_EXPRESSION:
			return execute_mod_expression(inter, scope, expr);
		case MF_EQ_EXPRESSION:
			return execute_eq_expression(inter, scope, expr);
		case MF_NE_EXPRESSION:
			return execute_ne_expression(inter, scope, expr);
		case MF_LT_EXPRESSION:
			return execute_lt_expression(inter, scope, expr);
		case MF_LE_EXPRESSION:
			return execute_le_expression(inter, scope, expr);
		case MF_GE_EXPRESSION:
			return execute_ge_expression(inter, scope, expr);
		case MF_GT_EXPRESSION:
			return execute_gt_expression(inter, scope, expr);
		case MF_LOGICAL_AND_EXPRESSION:
			return execute_logic_and_expression(inter, scope, expr);
		case MF_LOGICAL_OR_EXPRESSION:
			return execute_logic_or_expression(inter, scope, expr);
		case MF_LOGICAL_NOT_EXPRESSION:
			return execute_logic_not_expression(inter, scope, expr);
		case MF_TERNARY_EXPRESSION:
		 	return execute_ternary_expression(inter, scope, expr);
		case MF_SUB_SCRIPT_EXPRESSION:
			return execute_sub_script_expression(inter, scope, expr);
		case MF_AT_EXPRESSION:
			return execute_at_expression(inter, scope, expr);
        case MF_GET_ADDRESS_EXPRESSION:
            return execute_get_address_expresion(inter, scope, expr);
		case NSC_NEGATIVE_EXPRESSION:
			return execute_negative_expression(inter, scope, expr);
		case MF_MEMBER_EXPRESSION:
			return execute_member_expression(inter, scope, expr);
		case MF_DIC_LITERAL_EXPRESSION:
			return execute_dic_expression(inter, scope, expr);
		case MF_ARRAY_LITERAL_EXPRESSION:
			return execute_array_expression(inter, scope, expr);
		case MF_INCREMENT_EXPRESSION:
			return execute_increment_expression(inter, scope, expr);
		case MF_DECREMENT_EXPRESSION:
			return execute_decrement_expression(inter, scope, expr);
		case MF_STRUCT_LITERAL_EXPRESSION:
			return eval_struct_expression(inter, scope, expr);
		case MF_FUNCTION_CALL_EXPRESSION:
			return execute_function_call_expression(inter, scope, expr);
        case MF_C_FUNCTION_EXPRESSION:
            return execute_cfunction_expression(inter, scope, expr);
		default:
            return nil;
	}
	
}

MFValue *mf_execute_expression(MFInterpreter *inter, MFScopeChain *scope,MFExpression *expr){
	return execute_expression(inter, scope, expr);
}

