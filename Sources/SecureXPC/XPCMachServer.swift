//
//  XPCMachServer.swift
//  SwiftXPC
//
//  Created by Josh Kaplan on 2021-10-09
//

import Foundation

/// An XPC Mach Services server to receive calls from and send responses to ``XPCMachClient``.
///
/// ### Creating a Server
/// Because many processes on the system can talk to an XPC Mach Service, when creating a server it is required that you specificy the
/// security requirements of any connecting clients:
/// ```swift
/// let requirementString = """identifier "com.example.AuthorizedClient" and certificate leaf[subject.CN] = "Apple Development: Johnny Appleseed (4L0ZG128MM)" /* exists */"""
/// var requirement: SecRequirement?
/// if SecRequirementCreateWithString(requirementString as CFString,
///                                   SecCSFlags(),
///                                   &requirement) == errSecSuccess,
///   let requirement = requirement {
///    let server = XPCMachClient(machServiceName: "com.example.service",
///                               clientRequirements: [requirement])
///
///    <# configure and start server #>
/// }
/// ```
///
/// While in this example the requirement was shown as hardcoded, in practice if the server is running as part of an
/// executable installed via [`SMJobBless`](https://developer.apple.com/documentation/servicemanagement/1431078-smjobbless) then
/// use the array of client requirements specified by the
/// [`SMAuthorizedClients`](https://developer.apple.com/documentation/bundleresources/information_property_list/smauthorizedclients)
/// in the privileged executable's Info property list.
///
/// Incoming requests will be accepted from clients that meet _any_ of the specified requirements. If an empty array of
/// requirements is passed to the server, no requests will be accepted.
///
/// **Requirement checking**
///
/// On macOS 11 and later, requirement checking uses publicly documented APIs. On older versions of macOS, the private undocumented API
/// `void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *)` will be used; if for some reason the function is unavailable
/// then no messages will be accepted. When messages are not accepted, if the ``XPCMachServer/errorHandler`` is set then it is called
/// with ``XPCError/insecure``.
///
/// ### Registering & Handling Routes
/// Once a server instance has been created, one or more routes should be registered with it. This is done by calling one
/// of the `registerRoute` functions and providing a route and a compatible closure or function. For example:
/// ```swift
///     ...
///     let updateConfigRoute = XPCRouteWithMessageWithReply("update", "config",
///                                                          messageType:Config.self,
///                                                          replyType: Config.self)
///     server.registerRoute(updateConfigRoute, handler: updateConfig)
/// }
///
/// private func updateConfig(_ config: Config) throws -> Config {
///     <# implementation here #>
/// }
/// ```
///
/// If the function or closure provided as the `handler` parameter throws an error and the route expects a return, then
/// ``XPCError/remote(_:)`` will be returned to the client with the `String` associated type describing the thrown error. It
/// is intentional the thrown error is not marshalled as that type may not be `Codable` and may not exist in the client.
///
/// ### Starting a Server
/// Once all of the routes are registered, the server must be told to start processing messages:
/// ```swift
/// server.processMessages()
/// ```
///
/// This function replicates default [`xpc_main()`](https://developer.apple.com/documentation/xpc/1505740-xpc_main)
/// behavior by calling [`dispatchMain()`](https://developer.apple.com/documentation/dispatch/1452860-dispatchmain) and
/// never returning.
public class XPCMachServer {
    
    /// If set, errors encountered will be sent to this handler.
    public var errorHandler: ((XPCError) -> Void)?
    
    private let machService: xpc_connection_t
    private let clientRequirements: [SecRequirement]
    
    // Routes
    private var routesWithoutMessageWithReply = [XPCRoute : XPCHandlerWithoutMessageWithReply]()
    private var routesWithMessageWithReply = [XPCRoute : XPCHandlerWithMessageWithReply]()
    private var routesWithoutMessageWithoutReply = [XPCRoute : XPCHandlerWithoutMessageWithoutReply]()
    private var routesWithMessageWithoutReply = [XPCRoute : XPCHandlerWithMessageWithoutReply]()
    
    /// Creates a server that only processes messages from clients meeting the provided security requirements.
    ///
    /// No messages will be processed until ``processMessages()`` is called.
    ///
    /// - Parameters:
    ///   - machServiceName: The name of the mach service this server should bind to. This name must be present in this executable's (or app's)
    ///                      `launchd.plist` `MachServices` entry.
    ///   - clientRequirements: If a message is received from a client, it will only be processed if it meets one (or more) of these security requirements.
    public init(machServiceName: String, clientRequirements: [SecRequirement]) {
        self.clientRequirements = clientRequirements
        
        self.machService = machServiceName.withCString { serviceNamePointer in
            return xpc_connection_create_mach_service(serviceNamePointer,
                                                      nil,
                                                      UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        }
    }
    
    /// Registers a route that has no message and can't receive a reply.
    ///
    /// If this route has already been registered, calling this function will overwrite the existing registration. Routes are unique based on their paths and types.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and can't receive a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute(_ route: XPCRouteWithoutMessageWithoutReply,
                              handler: @escaping () throws -> Void) {
        let handlerWrapper = ConstrainedXPCHandlerWithoutMessageWithoutReply(handler: handler)
        self.routesWithoutMessageWithoutReply[route.route] = handlerWrapper
    }
    
    /// Registers a route that has a message and can't receive a reply.
    ///
    /// If this route has already been registered, calling this function will overwrite the existing registration. Routes are unique based on their paths and types.
    ///
    /// - Parameters:
    ///   - route: A route that has a message and can't receive a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<M: Decodable>(_ route: XPCRouteWithMessageWithoutReply<M>,
                                            handler: @escaping (M) throws -> Void) {
        let handlerWrapper = ConstrainedXPCHandlerWithMessageWithoutReply(handler: handler)
        self.routesWithMessageWithoutReply[route.route] = handlerWrapper
    }
    
    /// Registers a route that has no message and expects a reply.
    ///
    /// If this route has already been registered, calling this function will overwrite the existing registration. Routes are unique based on their paths and types.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and expects a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<R: Decodable>(_ route: XPCRouteWithoutMessageWithReply<R>,
                                            handler: @escaping () throws -> R) {
        let handlerWrapper = ConstrainedXPCHandlerWithoutMessageWithReply(handler: handler)
        self.routesWithoutMessageWithReply[route.route] = handlerWrapper
    }
    
    /// Registers a route that has no message and expects a reply.
    ///
    /// If this route has already been registered, calling this function will overwrite the existing registration. Routes are unique based on their paths and types.
    ///
    /// - Parameters:
    ///   - route: A route that has no message and expects a reply.
    ///   - handler: Will be called when the server receives an incoming request for this route if the request is accepted.
    public func registerRoute<M: Decodable, R: Encodable>(_ route: XPCRouteWithMessageWithReply<M, R>,
                                                          handler: @escaping (M) throws -> R) {
        let handlerWrapper = ConstrainedXPCHandlerWithMessageWithReply(handler: handler)
        self.routesWithMessageWithReply[route.route] = handlerWrapper
    }
    
    /// Begins processing messages sent to this XPC server.
    ///
    /// This function replicates [`xpc_main()`](https://developer.apple.com/documentation/xpc/1505740-xpc_main) behavior by never
    /// returning.
    public func processMessages() -> Never {
        // Start listener for the mach service, all received events should be for incoming client connections
        xpc_connection_set_event_handler(self.machService, { client in
            // Listen for events (messages or errors) coming from this client connection
            xpc_connection_set_event_handler(client, { event in
                self.handleEvent(client: client, event: event)
            })
            xpc_connection_resume(client)
        })
        xpc_connection_resume(self.machService)
        
        dispatchMain()
    }
    
    private func handleEvent(client: xpc_connection_t, event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
            if self.acceptMessage(client: client, message: event) {
                var reply = xpc_dictionary_create_reply(event)
                do {
                    try handleMessage(client: client, message: event, reply: &reply)
                } catch let error as XPCError {
                    self.errorHandler?(error)
                    self.replyWithErrorIfPossible(error, client: client, reply: &reply)
                } catch let error as DecodingError {
                    self.errorHandler?(XPCError.decodingError(error))
                    self.replyWithErrorIfPossible(error, client: client, reply: &reply)
                }  catch let error as EncodingError {
                    self.errorHandler?(XPCError.encodingError(error))
                    self.replyWithErrorIfPossible(error, client: client, reply: &reply)
                } catch {
                    self.errorHandler?(XPCError.other(error))
                    self.replyWithErrorIfPossible(error, client: client, reply: &reply)
                }
            } else {
                self.errorHandler?(XPCError.insecure)
            }
        } else if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
            self.errorHandler?(XPCError.connectionInvalid)
        } else if xpc_equal(event, XPC_ERROR_CONNECTION_INTERRUPTED) {
            self.errorHandler?(XPCError.connectionInterrupted)
        } else if xpc_equal(event, XPC_ERROR_TERMINATION_IMMINENT) {
            self.errorHandler?(XPCError.terminationImminent)
        } else {
            self.errorHandler?(XPCError.unknown)
        }
    }
    
    /// Determines whether the message should be accepted.
    ///
    /// This is determined using the client requirements provided to this server upon initialization.
    /// - Parameters:
    ///   - client: The client which sent the message.
    ///   - message: The message.
    /// - Returns: whether the message can be accepted
    private func acceptMessage(client: xpc_connection_t, message: xpc_object_t) -> Bool {
        // Get the code representing the client
        var code: SecCode?
        if #available(macOS 11, *) { // publicly documented, but only available since macOS 11
            SecCodeCreateWithXPCMessage(message, SecCSFlags(), &code)
        } else { // private undocumented function: xpc_connection_get_audit_token, available on prior versions of macOS
            if var auditToken = xpc_connection_get_audit_token(client) {
                let tokenData = NSData(bytes: &auditToken, length: MemoryLayout.size(ofValue: auditToken))
                let attributes = [kSecGuestAttributeAudit : tokenData] as NSDictionary
                SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
            }
        }
        
        // Accept message if code is valid and meets any of the client requirements
        var accept = false
        if let code = code {
            for requirement in self.clientRequirements {
                if SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess {
                    accept = true
                }
            }
        }
        
        return accept
    }
    
    /// Wrapper around the private undocumented function `void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *)`.
    ///
    /// - Parameters:
    ///   - _:  the connection for which the audit token will be retrieved for
    /// - Returns: the audit token or `nil` if the function could not be called
    ///
    /// The private undocumented function will attempt to be dynamically loaded and then invoked. If no function exists with this name `nil` will be returned. If
    /// the function does exist, but does not match the expected signature, the process calling this function is expected to crash. However, because this is only
    /// called on older versions of macOS which are expected to have a stable non-changing API this is very unlikely to occur.
    private func xpc_connection_get_audit_token(_ connection: xpc_connection_t) -> audit_token_t? {
        typealias functionSignature = @convention(c) (xpc_connection_t, UnsafeMutablePointer<audit_token_t>) -> Void
        let auditToken: audit_token_t?
        
        // Attempt to dynamically load the function
        if let handle = dlopen(nil, RTLD_LAZY) {
            defer { dlclose(handle) }
            if let sym = dlsym(handle, "xpc_connection_get_audit_token") {
                let function = unsafeBitCast(sym, to: functionSignature.self)
                
                // Call the function
                var token = audit_token_t()
                function(connection, &token)
                auditToken = token
            } else {
                auditToken = nil
            }
        } else {
            auditToken = nil
        }
        
        return auditToken
    }
    
    private func handleMessage(client: xpc_connection_t, message: xpc_object_t, reply: inout xpc_object_t?) throws {
        let route = try XPCDecoder.decodeRoute(message)
        let containsPayload = try XPCDecoder.containsPayload(message)
        
        // If a dictionary reply exists, then the message expects a reply
        if var reply = reply {
            if containsPayload {
                if let handler = self.routesWithMessageWithReply[route] {
                    try handler.handle(message: message, reply: &reply)
                    xpc_connection_send_message(client, reply)
                } else {
                    throw XPCError.routeNotRegistered(String(describing: route))
                }
            } else {
                if let handler = self.routesWithoutMessageWithReply[route] {
                    try handler.handle(reply: &reply)
                    xpc_connection_send_message(client, reply)
                } else {
                    throw XPCError.routeNotRegistered(String(describing: route))
                }
            }
        } else { // Otherwise the message can't receive a reply
            if containsPayload {
                if let handler = self.routesWithMessageWithoutReply[route] {
                    try handler.handle(message: message)
                } else {
                    throw XPCError.routeNotRegistered(String(describing: route))
                }
            } else {
                if let handler = self.routesWithoutMessageWithoutReply[route] {
                    try handler.handle()
                } else {
                    throw XPCError.routeNotRegistered(String(describing: route))
                }
            }
        }
    }
    
    private func replyWithErrorIfPossible(_ error: Error, client: xpc_connection_t, reply: inout xpc_object_t?) {
        if var reply = reply {
            do {
                try XPCEncoder.encodeError(error, forReply: &reply)
                xpc_connection_send_message(client, reply)
            } catch {
                // If encoding the error fails, then there's no way to proceed
            }
        }
    }
}

// MARK: handler function wrappers

// These wrappers perform type erasure via their implemented protocols while internally maintaining type constraints
// This makes it possible to create heterogenous collections of them

fileprivate protocol XPCHandlerWithoutMessageWithoutReply {
    func handle() throws -> Void
}

fileprivate struct ConstrainedXPCHandlerWithoutMessageWithoutReply: XPCHandlerWithoutMessageWithoutReply {
    let handler: () throws -> Void
    
    func handle() throws {
        try self.handler()
    }
}

fileprivate protocol XPCHandlerWithMessageWithoutReply {
    func handle(message: xpc_object_t) throws -> Void
}

fileprivate struct ConstrainedXPCHandlerWithMessageWithoutReply<M: Decodable>: XPCHandlerWithMessageWithoutReply {
    let handler: (M) throws -> Void
    
    func handle(message: xpc_object_t) throws {
        let decodedMessage = try XPCDecoder.decodePayload(message, asType: M.self)
        try self.handler(decodedMessage)
    }
}

fileprivate protocol XPCHandlerWithoutMessageWithReply {
    func handle(reply: inout xpc_object_t) throws
}

fileprivate struct ConstrainedXPCHandlerWithoutMessageWithReply<R: Encodable>: XPCHandlerWithoutMessageWithReply {
    let handler: () throws -> R
    
    func handle(reply: inout xpc_object_t) throws {
        let encodedReply = try self.handler()
        try XPCEncoder.encodeReply(&reply, value: encodedReply)
    }
}

fileprivate protocol XPCHandlerWithMessageWithReply {
    func handle(message: xpc_object_t, reply: inout xpc_object_t) throws
}

fileprivate struct ConstrainedXPCHandlerWithMessageWithReply<M: Decodable, R: Encodable>: XPCHandlerWithMessageWithReply {
    let handler: (M) throws -> R
    
    func handle(message: xpc_object_t, reply: inout xpc_object_t) throws {
        let decodedMessage = try XPCDecoder.decodePayload(message, asType: M.self)
        let encodedReply = try self.handler(decodedMessage)
        try XPCEncoder.encodeReply(&reply, value: encodedReply)
    }
}