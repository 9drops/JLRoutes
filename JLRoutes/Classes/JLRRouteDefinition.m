/*
 Copyright (c) 2017, Joel Levin
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 
 Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 Neither the name of JLRoutes nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "JLRRouteDefinition.h"
#import "JLRoutes.h"
#import "JLRParsingUtilities.h"


@interface JLRRouteDefinition ()

@property (nonatomic, copy) NSString *pattern;
@property (nonatomic, copy) NSString *scheme;
@property (nonatomic, assign) NSUInteger priority;
@property (nonatomic, strong) NSArray *patternPathComponents;
@property (nonatomic, copy) BOOL (^handlerBlock)(NSDictionary *parameters);

@end


@implementation JLRRouteDefinition

- (instancetype)initWithScheme:(NSString *)scheme pattern:(NSString *)pattern priority:(NSUInteger)priority handlerBlock:(BOOL (^)(NSDictionary *parameters))handlerBlock
{
    if ((self = [super init])) {
        self.scheme = scheme;
        self.pattern = pattern;
        self.priority = priority;
        self.handlerBlock = handlerBlock;
        
        if ([pattern characterAtIndex:0] == '/') {
            pattern = [pattern substringFromIndex:1];
        }
        
        self.patternPathComponents = [pattern componentsSeparatedByString:@"/"];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p> - %@ (priority: %@)", NSStringFromClass([self class]), self, self.pattern, @(self.priority)];
}

#pragma mark - Main API

- (JLRRouteResponse *)routeResponseForRequest:(JLRRouteRequest *)request
{
    BOOL patternContainsWildcard = [self.patternPathComponents containsObject:@"*"];
    
    if (request.pathComponents.count != self.patternPathComponents.count && !patternContainsWildcard) {
        // definitely not a match, nothing left to do
        return [JLRRouteResponse invalidMatchResponse];
    }
    
    NSDictionary *routeVariables = [self routeVariablesForRequest:request];
    
    if (routeVariables != nil) {
        // It's a match, set up the param dictionary and create a valid match response
        NSDictionary *matchParams = [self matchParametersForRequest:request routeVariables:routeVariables];
        return [JLRRouteResponse validMatchResponseWithParameters:matchParams];
    } else {
        // nil variables indicates no match, so return an invalid match response
        return [JLRRouteResponse invalidMatchResponse];
    }
}

- (BOOL)callHandlerBlockWithParameters:(NSDictionary *)parameters
{
    if (self.handlerBlock == nil) {
        return YES;
    }
    
    return self.handlerBlock(parameters);
}

#pragma mark - Parsing Route Variables

- (NSDictionary <NSString *, NSString *> *)routeVariablesForRequest:(JLRRouteRequest *)request
{
    NSMutableDictionary *routeVariables = [NSMutableDictionary dictionary];
    
    BOOL isMatch = YES;
    NSUInteger index = 0;
    
    for (NSString *patternComponent in self.patternPathComponents) {
        NSString *URLComponent = nil;
        BOOL isPatternComponentWildcard = [patternComponent isEqualToString:@"*"];
        
        if (index < [request.pathComponents count]) {
            URLComponent = request.pathComponents[index];
        } else if (!isPatternComponentWildcard) {
            // URLComponent is not a wildcard and index is >= request.pathComponents.count, so bail
            isMatch = NO;
            break;
        }
        
        if ([patternComponent hasPrefix:@":"]) {
            // this is a variable, set it in the params
            NSAssert(URLComponent != nil, @"URLComponent cannot be nil");
            NSString *variableName = [self variableNameForValue:patternComponent];
            NSString *variableValue = [self variableValueForValue:(NSString *)URLComponent];
            routeParams[variableName] = variableValue;
        } else if (isPatternComponentWildcard) {
            // match wildcards
            NSUInteger minRequiredParams = index;
            if (request.pathComponents.count >= minRequiredParams) {
                // match: /a/b/c/* has to be matched by at least /a/b/c
                routeVariables[JLRouteWildcardComponentsKey] = [request.pathComponents subarrayWithRange:NSMakeRange(index, request.pathComponents.count - index)];
                isMatch = YES;
            } else {
                // not a match: /a/b/c/* cannot be matched by URL /a/b/
                isMatch = NO;
            }
            break;
        } else if (![patternComponent isEqualToString:URLComponent]) {
            // break if this is a static component and it isn't a match
            isMatch = NO;
            break;
        }
        index++;
    }
    
    if (!isMatch) {
        // Return nil to indicate that there was not a match
        routeVariables = nil;
    }
    
    return [routeVariables copy];
}

- (NSString *)routeVariableNameForValue:(NSString *)value
{
    NSString *name = value;
    
    if (name.length > 1 && [name characterAtIndex:0] == ':') {
        // Strip off the ':' in front of param names
        name = [name substringFromIndex:1];
    }
    
    if (name.length > 1 && [name characterAtIndex:name.length - 1] == '#') {
        // Strip of trailing fragment
        name = [name substringToIndex:name.length - 1];
    }
    
    return name;
}

- (NSString *)routeVariableValueForValue:(NSString *)value
{
    // Remove percent encoding
    NSString *var = [value stringByRemovingPercentEncoding];
    
    if (var.length > 1 && [var characterAtIndex:var.length - 1] == '#') {
        // Strip of trailing fragment
        var = [var substringToIndex:var.length - 1];
    }
    
    // Consult the parsing utilities as well to do any other global variable transformations.
    var = [JLRParsingUtilities variableValueFrom:var decodePlusSymbols:[JLRoutes shouldDecodePlusSymbols]];
    
    return var;
}

#pragma mark - Creating Match Parameters

- (NSDictionary *)matchParametersForRequest:(JLRRouteRequest *)request routeVariables:(NSDictionary <NSString *, NSString *> *)routeVariables
{
    NSMutableDictionary *matchParams = [NSMutableDictionary dictionary];
    
    // First, add the parsed query parameters ('?a=b&c=d'). Also includes fragment.
    [matchParams addEntriesFromDictionary:[JLRParsingUtilities queryParams:request.queryParams decodePlusSymbols:[JLRoutes shouldDecodePlusSymbols]]];
    
    // Next, add the actual parsed route variables (the items in the route prefixed with ':')
    [matchParams addEntriesFromDictionary:routeVariables];
    
    // Finally, add the base parameters. This is done last so that these cannot be overriden by using the same key in your route or query.
    [matchParams addEntriesFromDictionary:[self defaultMatchParametersForRequest:request]];
    
    return [matchParams copy];
}

- (NSDictionary *)defaultMatchParametersForRequest:(JLRRouteRequest *)request
{
    return @{JLRoutePatternKey: self.pattern ?: [NSNull null], JLRouteURLKey: request.URL ?: [NSNull null], JLRouteSchemeKey: self.scheme ?: [NSNull null]};
}

@end
