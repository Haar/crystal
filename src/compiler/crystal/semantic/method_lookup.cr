require "../types"

module Crystal
  class Type
    def lookup_matches(signature, owner = self, type_lookup = self, matches_array = nil)
      raise "Bug: #{self} doesn't implement lookup_matches"
    end

    def lookup_matches_without_parents(signature, owner = self, type_lookup = self, matches_array = nil)
      raise "Bug: #{self} doesn't implement lookup_matches_without_parents"
    end

    def lookup_matches_with_modules(signature, owner = self, type_lookup = self, matches_array = nil)
      raise "Bug: #{self} doesn't implement lookup_matches_with_modules"
    end
  end

  module MatchesLookup
    def lookup_matches_without_parents(signature, owner = self, type_lookup = self, matches_array = nil)
      if defs = self.defs.try &.[signature.name]?
        context = MatchContext.new(owner, type_lookup)

        defs.each do |item|
          next if item.def.abstract?

          # If the def has a macro owner, which means that the original
          # def was defined via a `macro def` and copied to a subtype,
          # we need to use the type that defined the `macro def` as a
          # type lookup for arguments.
          macro_owner = item.def.macro_owner?
          context.type_lookup = macro_owner if macro_owner

          match = MatchesLookup.match_def(signature, item, context)

          context.type_lookup = type_lookup if macro_owner

          if match
            matches_array ||= [] of Match
            matches_array << match

            # If the argument types are compatible with the match's argument types,
            # we are done. We don't just compare types with ==, there is a special case:
            # a function type with return T can be transpass a restriction of a function
            # with with the same arguments but which returns Void.
            if signature.arg_types.equals?(match.arg_types) { |x, y| x.compatible_with?(y) }
              return Matches.new(matches_array, true, owner)
            end
          end
        end
      end

      Matches.new(matches_array, Cover.create(signature.arg_types, matches_array), owner)
    end

    def lookup_matches_with_modules(signature, owner = self, type_lookup = self, matches_array = nil)
      matches = lookup_matches_without_parents(signature, owner, type_lookup, matches_array)
      return matches unless matches.empty?

      is_new = owner.metaclass? && signature.name == "new"
      if is_new
        # For a `new` method we need to do this in case a `new` is defined
        # in a module type
        my_parents = instance_type.parents.try &.map(&.metaclass)
      else
        my_parents = parents
      end

      # `new` must only be searched in ancestors if this type itself doesn't define
      # an `initialize` or `self.new` method. This was already computed in `new.cr`
      # and can be known by invoking `lookup_new_in_ancestors?`
      if my_parents && !(!lookup_new_in_ancestors? && is_new)
        my_parents.each do |parent|
          break unless parent.is_a?(IncludedGenericModule) || parent.module?

          matches = parent.lookup_matches_with_modules(signature, owner, parent, matches_array)
          return matches unless matches.empty?
        end
      end

      Matches.new(matches_array, Cover.create(signature.arg_types, matches_array), owner, false)
    end

    def lookup_matches(signature, owner = self, type_lookup = self, matches_array = nil)
      matches = lookup_matches_without_parents(signature, owner, type_lookup, matches_array)
      return matches if matches.cover_all?

      matches_array = matches.matches

      cover = matches.cover

      is_new = owner.metaclass? && signature.name == "new"
      if is_new
        # For a `new` method we need to do this in case a `new` is defined
        # in a module type
        my_parents = instance_type.parents.try &.map(&.metaclass)
      else
        my_parents = parents
      end

      # `new` must only be searched in ancestors if this type itself doesn't define
      # an `initialize` or `self.new` method. This was already computed in `new.cr`
      # and can be known by invoking `lookup_new_in_ancestors?`
      if my_parents && !(!lookup_new_in_ancestors? && is_new)
        my_parents.each do |parent|
          matches = parent.lookup_matches(signature, owner, parent, matches_array)
          if matches.cover_all?
            return matches
          else
            matches_array = matches.matches
          end
        end
      end

      Matches.new(matches_array, cover, owner, false)
    end

    def self.match_def(signature, def_metadata, context)
      # If yieldness isn't the same there's no match
      if def_metadata.yields != !!signature.block
        return nil
      end

      # If there are more positional arguments than those required, there's no match
      # (if there's less they might be matched with named arguments)
      if signature.arg_types.size > def_metadata.max_size
        return nil
      end

      a_def = def_metadata.def
      arg_types = signature.arg_types
      named_args = signature.named_args
      splat_index = a_def.splat_index

      # If there are arguments past the splat index and no named args, there's no match,
      # unless all args past it have default values
      if splat_index && a_def.args.size > splat_index + 1 && !named_args
        unless (splat_index + 1...a_def.args.size).all? { |i| a_def.args[i].default_value }
          return nil
        end
      end

      # If there are named args we must check that all mandatory args
      # are covered by positional arguments or named arguments.
      if named_args
        mandatory_args = BitArray.new(a_def.args.size)
      elsif signature.arg_types.size < def_metadata.min_size
        # Otherwise, they must be matched by positional arguments
        return nil
      end

      matched_arg_types = nil

      # If there's a restriction on a splat, zero splatted args don't match
      if splat_index &&
         a_def.args[splat_index].restriction &&
         Splat.size(a_def, arg_types) == 0
        return nil
      end

      a_def.match(arg_types) do |arg, arg_index, arg_type, arg_type_index|
        match_arg_type = match_arg(arg_type, arg, context)
        if match_arg_type
          matched_arg_types ||= [] of Type
          matched_arg_types.push match_arg_type
          mandatory_args[arg_index] = true if mandatory_args
        else
          return nil
        end
      end

      # Check named args
      if named_args
        min_index = signature.arg_types.size
        named_args.each do |named_arg|
          found_index = a_def.args.index { |arg| arg.external_name == named_arg.name }
          if found_index
            # A named arg can't target the splat index
            if found_index == splat_index
              return nil
            end

            # Check whether the named arg refers to an argument that was already specified
            if mandatory_args
              if mandatory_args[found_index]
                return nil
              end
              mandatory_args[found_index] = true
            else
              if found_index < min_index
                return nil
              end
            end

            unless match_arg(named_arg.type, a_def.args[found_index], context)
              return nil
            end
          else
            # If there's a double splat it's ok, the named arg will be put there
            next if a_def.double_splat

            return nil
          end
        end
      end

      # Check that all mandatory args were specified
      # (either with positional arguments or with named arguments)
      if mandatory_args
        a_def.args.each_with_index do |arg, index|
          if index != splat_index && !arg.default_value && !mandatory_args[index]
            return nil
          end
        end
      end

      # We reuse a match context without free vars, but we create
      # new ones when there are free vars.
      context = context.clone if context.free_vars

      Match.new(a_def, (matched_arg_types || arg_types), context)
    end

    def self.match_arg(arg_type, arg : Arg, context : MatchContext)
      restriction = arg.type? || arg.restriction
      match_arg arg_type, restriction, context
    end

    def self.match_arg(arg_type, restriction, context : MatchContext)
      arg_type.not_nil!.restrict restriction, context
    end
  end

  class EmptyType
    def lookup_matches(signature, owner = self, type_lookup = self, matches_array = nil)
      Matches.new(nil, nil, self, false)
    end
  end

  class AliasType
    delegate lookup_matches, aliased_type
    delegate lookup_matches_without_parents, aliased_type
  end

  module VirtualTypeLookup
    def lookup_matches(signature, owner = self, type_lookup = self)
      is_new = virtual_metaclass? && signature.name == "new"

      base_type_lookup = virtual_lookup(base_type)
      base_type_matches = base_type_lookup.lookup_matches(signature, self)

      # If there are no subclasses no need to look further
      if leaf?
        return base_type_matches
      end

      base_type_covers_all = base_type_matches.cover_all?

      # If the base type doesn't cover every possible type combination, it's a failure
      if !base_type.abstract? && !base_type_covers_all
        return Matches.new(base_type_matches.matches, base_type_matches.cover, base_type_lookup, false)
      end

      type_to_matches = nil
      matches = base_type_matches.matches
      changes = nil

      # Traverse all subtypes
      instance_type.subtypes(base_type).each do |subtype|
        unless subtype.value?
          subtype_lookup = virtual_lookup(subtype)
          subtype_virtual_lookup = virtual_lookup(subtype.virtual_type)

          # Check matches but without parents: only included modules
          subtype_matches = subtype_lookup.lookup_matches_with_modules(signature, subtype_virtual_lookup, subtype_virtual_lookup)

          # For Foo+:Class#new we need to check that this subtype doesn't define
          # an incompatible initialize: if so, we return empty matches, because
          # all subtypes must have an initialize with the same number of arguments.
          if is_new && subtype_matches.empty?
            other_initializers = subtype_lookup.instance_type.lookup_defs_with_modules("initialize")
            unless other_initializers.empty?
              return Matches.new(nil, false)
            end
          end

          # If we didn't find a match in a subclass, and the base type match is a macro
          # def, we need to copy it to the subclass so that @name, @instance_vars and other
          # macro vars resolve correctly.
          if subtype_matches.empty?
            new_subtype_matches = nil

            base_type_matches.each do |base_type_match|
              if base_type_match.def.macro_def?
                # We need to copy each submatch if it's a macro def
                full_subtype_matches = subtype_lookup.lookup_matches(signature, subtype_virtual_lookup, subtype_virtual_lookup)
                full_subtype_matches.each do |full_subtype_match|
                  cloned_def = full_subtype_match.def.clone
                  cloned_def.macro_owner = full_subtype_match.def.macro_owner
                  cloned_def.owner = subtype_lookup

                  # We want to add this cloned def at the end, because if we search subtype matches
                  # in the next iteration we will find it, and we don't want that.
                  changes ||= [] of Change
                  changes << Change.new(subtype_lookup, cloned_def)

                  new_subtype_matches ||= [] of Match
                  new_subtype_matches.push Match.new(cloned_def, full_subtype_match.arg_types, MatchContext.new(subtype_lookup, full_subtype_match.context.type_lookup, full_subtype_match.context.free_vars))
                end
              end
            end

            if new_subtype_matches
              subtype_matches = Matches.new(new_subtype_matches, Cover.create(signature.arg_types, new_subtype_matches))
            end
          end

          if !subtype.leaf? && subtype_matches.size > 0
            type_to_matches ||= {} of Type => Matches
            type_to_matches[subtype] = subtype_matches
          end

          # If the subtype is non-abstract but doesn't cover all,
          # we need to check if a parent covers it
          if !subtype.abstract? && !base_type_covers_all && !subtype_matches.cover_all?
            unless covered_by_superclass?(subtype, type_to_matches)
              return Matches.new(subtype_matches.matches, subtype_matches.cover, subtype_lookup, false)
            end
          end

          if !subtype_matches.empty? && (subtype_matches_matches = subtype_matches.matches)
            if subtype.abstract? && !self.is_a?(VirtualMetaclassType) && subtype.subclasses.empty?
              # No need to add matches if for an abstract class without subclasses
            else
              # We need to insert the matches before the previous ones
              # because subtypes are more specific matches
              if matches
                subtype_matches_matches.concat matches
              end
              matches = subtype_matches_matches
            end
          end
        end
      end

      changes.try &.each do |change|
        change.type.add_def change.def
      end

      Matches.new(matches, !!(matches && matches.size > 0), self)
    end

    def covered_by_superclass?(subtype, type_to_matches)
      superclass = subtype.superclass
      while superclass && superclass != base_type
        superclass_matches = type_to_matches.try &.[superclass]?
        if superclass_matches && superclass_matches.cover_all?
          return true
        end
        superclass = superclass.superclass
      end
      false
    end
  end
end
