(function_declaration body: (_ "{" (_)* @function.inside "}")) @function.around
(method_declaration body: (_ "{" (_)* @function.inside "}")) @function.around
(test_declaration body: (_ "{" (_)* @function.inside "}")) @function.around
(compound_declaration body: (_ "{" (_)* @class.inside "}")) @class.around
(enum_declaration body: (_ "{" (_)* @class.inside "}")) @class.around
(quirk_declaration body: (_ "{" (_)* @class.inside "}")) @class.around
(impl_declaration body: (_ "{" (_)* @class.inside "}")) @class.around
(comment)+ @comment.around
